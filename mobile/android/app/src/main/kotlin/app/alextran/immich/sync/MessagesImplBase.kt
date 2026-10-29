package app.alextran.immich.sync

import android.annotation.SuppressLint
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.ext.SdkExtensions
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import androidx.core.database.getStringOrNull
import app.alextran.immich.core.ImmichPlugin
import com.bumptech.glide.Glide
import com.bumptech.glide.load.ImageHeaderParser
import com.bumptech.glide.load.ImageHeaderParserUtils
import com.bumptech.glide.load.resource.bitmap.DefaultImageHeaderParser
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import kotlin.coroutines.cancellation.CancellationException

sealed class AssetResult {
  data class ValidAsset(val asset: PlatformAsset, val albumId: String) : AssetResult()
  data class InvalidAsset(val assetId: String) : AssetResult()
}

private const val TAG = "NativeSyncApiImplBase"

@SuppressLint("InlinedApi")
open class NativeSyncApiImplBase(context: Context) : ImmichPlugin(), ActivityAware {
  private val ctx: Context = context.applicationContext

  private var hashTask: Job? = null
  private var syncJob: Job? = null
  private val mediaTrashDelegate = MediaTrashDelegate(ctx)

  private val prefs = ctx.getSharedPreferences(SHARED_PREF_NAME, Context.MODE_PRIVATE)

  // The folder and volume of each album and the mounted volumes when the current sync listed the albums. An album is
  // a folder, which lies on one volume, so the deletion sync can tell the albums of an ejected volume apart
  @Volatile
  private var albumFoldersAtAlbumQuery: Map<String, String>? = null

  @Volatile
  private var albumVolumesAtAlbumQuery: Map<String, String> = emptyMap()

  @Volatile
  private var volumesAtAlbumQuery: Set<String> = emptySet()

  companion object {
    private const val MAX_CONCURRENT_HASH_OPERATIONS = 16
    private val hashSemaphore = Semaphore(MAX_CONCURRENT_HASH_OPERATIONS)
    private const val HASHING_CANCELLED_CODE = "HASH_CANCELLED"
    private const val SYNC_CANCELLED_CODE = "SYNC_CANCELLED"

    // MediaStore.Files.FileColumns.SPECIAL_FORMAT — S Extensions 21+
    // https://developer.android.com/reference/android/provider/MediaStore.Files.FileColumns#SPECIAL_FORMAT
    private const val SPECIAL_FORMAT_COLUMN = "_special_format"
    private const val SPECIAL_FORMAT_GIF = 1
    private const val SPECIAL_FORMAT_MOTION_PHOTO = 2
    private const val SPECIAL_FORMAT_ANIMATED_WEBP = 3

    const val MEDIA_SELECTION =
      "(${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?)"
    val MEDIA_SELECTION_ARGS = arrayOf(
      MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
      MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
    )
    const val BUCKET_SELECTION = "(${MediaStore.Files.FileColumns.BUCKET_ID} = ?)"
    val ASSET_PROJECTION = buildList {
      add(MediaStore.MediaColumns._ID)
      add(MediaStore.MediaColumns.DATA)
      add(MediaStore.MediaColumns.DISPLAY_NAME)
      add(MediaStore.MediaColumns.DATE_TAKEN)
      add(MediaStore.MediaColumns.DATE_ADDED)
      add(MediaStore.MediaColumns.DATE_MODIFIED)
      add(MediaStore.Files.FileColumns.MEDIA_TYPE)
      add(MediaStore.MediaColumns.BUCKET_ID)
      add(MediaStore.MediaColumns.WIDTH)
      add(MediaStore.MediaColumns.HEIGHT)
      add(MediaStore.MediaColumns.DURATION)
      add(MediaStore.MediaColumns.ORIENTATION)
      // IS_FAVORITE is only available on Android 11 and above
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        add(MediaStore.MediaColumns.IS_FAVORITE)
      }
      if (hasSpecialFormatColumn()) {
        add(SPECIAL_FORMAT_COLUMN)
      } else {
        // fallback to mimetype and xmp for playback style detection on older Android versions
        // both only needed if special format column is not available
        add(MediaStore.MediaColumns.MIME_TYPE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          add(MediaStore.MediaColumns.XMP)
        }
      }
    }.toTypedArray()

    const val HASH_BUFFER_SIZE = 2 * 1024 * 1024

    // Keep IN clauses below SQLite's default bound-variable limit (999).
    private const val SQLITE_MAX_VARIABLE_NUMBER = 900

    private const val SHARED_PREF_NAME = "Immich::MediaManager"
    private const val SHARED_PREF_ALBUM_FOLDERS_KEY = "MediaStore::albumFolders"
    private const val SHARED_PREF_ALBUM_VOLUMES_KEY = "MediaStore::albumVolumes"

    // The name of the primary volume before Android 10, which has no MediaStore volume names
    private const val PRIMARY_VOLUME = "primary"

    // The folder and volume of an album whose files lie in several folders or in none that is known. Never a mounted
    // volume
    private const val UNKNOWN = ""

    // _special_format: added in API level 37, also in S Extensions 21+
    // https://developer.android.com/reference/android/provider/MediaStore.Files.FileColumns#SPECIAL_FORMAT
    private fun hasSpecialFormatColumn(): Boolean =
      Build.VERSION.SDK_INT >= 37 ||
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
          SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 21)
  }

  protected fun getCursor(
    volume: String,
    selection: String,
    selectionArgs: Array<String>,
    projection: Array<String> = ASSET_PROJECTION,
    sortOrder: String? = null
  ): Cursor? = ctx.contentResolver.query(
    MediaStore.Files.getContentUri(volume),
    projection,
    selection,
    selectionArgs,
    sortOrder,
  )

  protected fun getCursor(
    volume: String,
    queryArgs: Bundle
  ): Cursor? = ctx.contentResolver.query(
    MediaStore.Files.getContentUri(volume),
    ASSET_PROJECTION,
    queryArgs,
    null
  )

  protected fun getAssets(cursor: Cursor?): Sequence<AssetResult> {
    return sequence {
      cursor?.use { c ->
        val idColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
        val dataColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
        val nameColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
        val dateTakenColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
        val dateAddedColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
        val dateModifiedColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
        val mediaTypeColumn = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
        val mimeTypeColumn = c.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
        val bucketIdColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
        val widthColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
        val heightColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
        val durationColumn = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)
        val orientationColumn =
          c.getColumnIndexOrThrow(MediaStore.MediaColumns.ORIENTATION)
        val favoriteColumn = c.getColumnIndex(MediaStore.MediaColumns.IS_FAVORITE)
        val specialFormatColumn = c.getColumnIndex(SPECIAL_FORMAT_COLUMN)
        val xmpColumn = c.getColumnIndex(MediaStore.MediaColumns.XMP)

        while (c.moveToNext()) {
          val numericId = c.getLong(idColumn)
          val id = numericId.toString()
          val name = c.getStringOrNull(nameColumn)
          val bucketId = c.getStringOrNull(bucketIdColumn)
          val path = c.getStringOrNull(dataColumn)

          // Skip assets with invalid metadata
          if (
            name.isNullOrBlank() || bucketId.isNullOrBlank() ||
            path.isNullOrBlank() || !File(path).exists()
          ) {
            yield(AssetResult.InvalidAsset(id))
            continue
          }

          val rawMediaType = c.getInt(mediaTypeColumn)
          val assetType: Long = when (rawMediaType) {
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> 1L
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> 2L
            else -> 0L
          }
          // Date taken is in ms; added/modified are in seconds, and modified can be 0 when unset.
          // If EXIF date taken exists use it, else if modified is empty use added, else the earliest of the two.
          val modifiedAt = c.getLong(dateModifiedColumn)
          val addedAt = c.getLong(dateAddedColumn)
          val createdAt = (c.getLong(dateTakenColumn).takeIf { it > 0 }?.div(1000))
            ?: if (modifiedAt <= 0) addedAt else minOf(modifiedAt, addedAt)
          val width = c.getInt(widthColumn).toLong()
          val height = c.getInt(heightColumn).toLong()
          // Duration is milliseconds
          val duration = if (rawMediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE) 0L
          else c.getLong(durationColumn)
          val orientation = c.getInt(orientationColumn)
          val isFavorite = if (favoriteColumn == -1) false else c.getInt(favoriteColumn) != 0

          val playbackStyle = detectPlaybackStyle(
            numericId, rawMediaType, mimeTypeColumn, specialFormatColumn, xmpColumn, c
          )

          val isFlipped = orientation == 90 || orientation == 270
          val asset = PlatformAsset(
            id,
            name,
            assetType,
            createdAt,
            modifiedAt,
            if (isFlipped) height else width,
            if (isFlipped) width else height,
            duration,
            0L,
            isFavorite,
            playbackStyle = playbackStyle,
          )
          yield(AssetResult.ValidAsset(asset, bucketId))
        }
      }
    }
  }

  /**
   * Detects the playback style for an asset using _special_format (SDK Extension 21+)
   * or XMP / MIME / RIFF header fallbacks.
   */
  @SuppressLint("NewApi")
  private fun detectPlaybackStyle(
    assetId: Long,
    rawMediaType: Int,
    mimeTypeColumn: Int,
    specialFormatColumn: Int,
    xmpColumn: Int,
    cursor: Cursor
  ): PlatformAssetPlaybackStyle {
    // video currently has no special formats, so we can short circuit and avoid unnecessary work
    if (rawMediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
      return PlatformAssetPlaybackStyle.VIDEO
    }

    // API 33+: use _special_format from cursor
    if (specialFormatColumn != -1) {
      val specialFormat = cursor.getInt(specialFormatColumn)
      return when {
        specialFormat == SPECIAL_FORMAT_MOTION_PHOTO -> PlatformAssetPlaybackStyle.LIVE_PHOTO
        specialFormat == SPECIAL_FORMAT_GIF || specialFormat == SPECIAL_FORMAT_ANIMATED_WEBP -> PlatformAssetPlaybackStyle.IMAGE_ANIMATED
        rawMediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> PlatformAssetPlaybackStyle.IMAGE
        else -> PlatformAssetPlaybackStyle.UNKNOWN
      }
    }

    if (rawMediaType != MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE) {
      return PlatformAssetPlaybackStyle.UNKNOWN
    }

    val mimeType = if (mimeTypeColumn != -1) cursor.getString(mimeTypeColumn) else null

    // GIFs are always animated and cannot be motion photos; no I/O needed
    if (mimeType == "image/gif") {
      return PlatformAssetPlaybackStyle.IMAGE_ANIMATED
    }

    val uri = ContentUris.withAppendedId(
      MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
      assetId
    )

    // Only WebP needs a stream check to distinguish static vs animated;
    // WebP files are not used as motion photos, so skip XMP detection
    if (mimeType == "image/webp") {
      try {
        val glide = Glide.get(ctx)
        ctx.contentResolver.openInputStream(uri)?.use { stream ->
          val type = ImageHeaderParserUtils.getType(
            listOf(DefaultImageHeaderParser()),
            stream,
            glide.arrayPool
          )
          // Also check for GIF just in case MIME type is incorrect; Doesn't hurt performance
          if (type == ImageHeaderParser.ImageType.ANIMATED_WEBP || type == ImageHeaderParser.ImageType.GIF) {
            return PlatformAssetPlaybackStyle.IMAGE_ANIMATED
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "Failed to parse image header for asset $assetId", e)
      }
      // if mimeType is webp but not animated, its just an image.
      return PlatformAssetPlaybackStyle.IMAGE
    }


    // Read XMP from cursor (API 30+)
    val xmp: String? = if (xmpColumn != -1) {
      cursor.getBlob(xmpColumn)?.toString(Charsets.UTF_8)
    } else {
      // if xmp column is not available, we are on API 29 or below
      // theoretically there were motion photos but the Camera:MotionPhoto xmp tag
      // was only added in Android 11, so we should not have to worry about parsing XMP on older versions
      null
    }

    if (xmp != null && "Camera:MotionPhoto" in xmp) {
      return PlatformAssetPlaybackStyle.LIVE_PHOTO
    }

    return PlatformAssetPlaybackStyle.IMAGE
  }

  fun getAlbums(callback: (Result<List<PlatformAlbum>>) -> Unit) {
    runSync(callback) { getAlbums() }
  }

  private suspend fun getAlbums(): List<PlatformAlbum> {
    volumesAtAlbumQuery = getMountedVolumes()
    val albums = mutableListOf<PlatformAlbum>()
    val albumsCount = mutableMapOf<String, Int>()
    val albumFolders = mutableMapOf<String, String>()
    val albumVolumes = mutableMapOf<String, String>()

    val projection = buildList {
      add(MediaStore.Files.FileColumns.BUCKET_ID)
      add(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
      add(MediaStore.Files.FileColumns.DATE_MODIFIED)
      add(MediaStore.MediaColumns.DATA)
      // Before Android 10 the volume is found from the path
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        add(MediaStore.MediaColumns.VOLUME_NAME)
      }
    }.toTypedArray()
    val selection =
      "(${MediaStore.Files.FileColumns.BUCKET_ID} IS NOT NULL) AND $MEDIA_SELECTION"

    val cursor = getCursor(
      MediaStore.VOLUME_EXTERNAL,
      selection,
      MEDIA_SELECTION_ARGS,
      projection,
      "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
    ) ?: error("MediaStore album query failed")
    cursor.use {
      val bucketIdColumn =
        cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID)
      val bucketNameColumn =
        cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
      val dateModified =
        cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
      val dataColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
      val volumeColumn = cursor.getColumnIndex(MediaStore.MediaColumns.VOLUME_NAME)

      while (cursor.moveToNext()) {
        currentCoroutineContext().ensureActive()
        val id = cursor.getString(bucketIdColumn)

        // The id hashes the lowercased folder path, so two folders only share it by a collision. Rows of one folder can
        // spell its path in another case, which the storage resolves alike
        val folder = cursor.getStringOrNull(dataColumn)?.let { File(it).parent } ?: UNKNOWN
        val albumFolder = albumFolders.putIfAbsent(id, folder)
        if (albumFolder == null) {
          albumVolumes[id] = when {
            folder == UNKNOWN -> UNKNOWN
            volumeColumn >= 0 -> cursor.getStringOrNull(volumeColumn) ?: UNKNOWN
            else -> getStorageVolume(folder)
          }
        } else if (!albumFolder.equals(folder, ignoreCase = true)) {
          albumFolders[id] = UNKNOWN
          albumVolumes[id] = UNKNOWN
        }

        val count = albumsCount.getOrDefault(id, 0)
        if (count != 0) {
          albumsCount[id] = count + 1
          continue
        }

        // MediaStore might return null for bucket name (commonly for the Root Directory), so default to "Internal Storage"
        val name = cursor.getStringOrNull(bucketNameColumn) ?: "Internal Storage"
        val updatedAt = cursor.getLong(dateModified)
        albums.add(PlatformAlbum(id, name, updatedAt, false, 0, false))
        albumsCount[id] = 1
      }
    }
    albumVolumesAtAlbumQuery = albumVolumes
    albumFoldersAtAlbumQuery = albumFolders

    return albums.map { it.copy(assetCount = albumsCount[it.id]?.toLong() ?: 0) }
      .sortedBy { it.id }
  }

  // The names of the mounted volumes, as getAlbums finds them for the albums
  private fun getMountedVolumes(): Set<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.getExternalVolumeNames(ctx)
    } else {
      ctx.getSystemService(StorageManager::class.java)?.storageVolumes.orEmpty()
        .filter { it.state == Environment.MEDIA_MOUNTED }
        .map { it.uuid ?: PRIMARY_VOLUME }
        .toSet()
    }

  private fun getStorageVolume(path: String): String =
    runCatching { ctx.getSystemService(StorageManager::class.java)?.getStorageVolume(File(path)) }.getOrNull()
      ?.let { it.uuid ?: PRIMARY_VOLUME } ?: UNKNOWN

  // Lets the next sync know where the albums lie that it no longer lists
  protected fun saveAlbumLocations() {
    val albumFolders = albumFoldersAtAlbumQuery ?: return
    runCatching {
      prefs.edit().apply {
        putString(SHARED_PREF_ALBUM_FOLDERS_KEY, Json.encodeToString(albumFolders))
        putString(SHARED_PREF_ALBUM_VOLUMES_KEY, Json.encodeToString(albumVolumesAtAlbumQuery))
        apply()
      }
    }
  }

  private fun getSavedAlbumLocations(key: String): Map<String, String> =
    runCatching { prefs.getString(key, null)?.let { Json.decodeFromString<Map<String, String>>(it) } }
      .getOrNull().orEmpty()

  fun getMissingAssetIds(assets: List<PlatformAssetFile>): List<String> {
    val listedFolders = albumFoldersAtAlbumQuery.orEmpty()
    val listedVolumes = albumVolumesAtAlbumQuery
    // The folder of an album that this sync no longer lists comes from the last sync
    val allListed = assets.all { it.albumId in listedFolders }
    val savedFolders = if (allListed) emptyMap() else getSavedAlbumLocations(SHARED_PREF_ALBUM_FOLDERS_KEY)
    val savedVolumes = if (allListed) emptyMap() else getSavedAlbumLocations(SHARED_PREF_ALBUM_VOLUMES_KEY)
    val mounted = getMountedVolumes()
    val missing = assets.filter { asset ->
      val folder = listedFolders[asset.albumId] ?: savedFolders[asset.albumId] ?: UNKNOWN
      val volume = listedVolumes[asset.albumId] ?: savedVolumes[asset.albumId] ?: UNKNOWN
      // A volume that is not mounted now or was not when the albums were listed, e.g. an ejected SD card, or that is
      // unknown, keeps its files. A file that is still in its folder got a new id, e.g. when MediaStore scanned its
      // volume anew, which Android 9 and older do for an SD card that was out
      folder != UNKNOWN && volume in volumesAtAlbumQuery && volume in mounted && !File(folder, asset.name).exists()
    }
    // A volume ejected during the checks takes its files along
    val stillMounted = getMountedVolumes()
    return missing.filter { asset ->
      (listedVolumes[asset.albumId] ?: savedVolumes[asset.albumId] ?: UNKNOWN) in stillMounted
    }.map { it.id }
  }

  fun getAssetIdsForAlbum(albumId: String, callback: (Result<List<String>>) -> Unit) {
    runSync(callback) { getAssetIdsForAlbum(albumId) }
  }

  private fun getAssetIdsForAlbum(albumId: String): List<String> {
    val projection = arrayOf(MediaStore.MediaColumns._ID)

    return getCursor(
      MediaStore.VOLUME_EXTERNAL,
      "$BUCKET_SELECTION AND $MEDIA_SELECTION",
      arrayOf(albumId, *MEDIA_SELECTION_ARGS),
      projection
    )?.use { cursor ->
      val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
      generateSequence {
        if (cursor.moveToNext()) cursor.getLong(idColumn).toString() else null
      }.toList()
    } ?: emptyList()
  }

  fun getAssetsCountSince(albumId: String, timestamp: Long): Long =
    getCursor(
      MediaStore.VOLUME_EXTERNAL,
      "$BUCKET_SELECTION AND ${MediaStore.Files.FileColumns.DATE_ADDED} > ? AND $MEDIA_SELECTION",
      arrayOf(albumId, timestamp.toString(), *MEDIA_SELECTION_ARGS),
    )?.use { cursor -> cursor.count.toLong() } ?: 0L


  fun getAssetsForAlbum(
    albumId: String,
    updatedTimeCond: Long?,
    callback: (Result<List<PlatformAsset>>) -> Unit
  ) {
    runSync(callback) { getAssetsForAlbum(albumId, updatedTimeCond) }
  }

  private fun getAssetsForAlbum(albumId: String, updatedTimeCond: Long?): List<PlatformAsset> {
    var selection = "$BUCKET_SELECTION AND $MEDIA_SELECTION"
    val selectionArgs = mutableListOf(albumId, *MEDIA_SELECTION_ARGS)

    if (updatedTimeCond != null) {
      selection += " AND (${MediaStore.Files.FileColumns.DATE_MODIFIED} > ? OR ${MediaStore.Files.FileColumns.DATE_ADDED} > ?)"
      selectionArgs.addAll(listOf(updatedTimeCond.toString(), updatedTimeCond.toString()))
    }

    val cursor = getCursor(MediaStore.VOLUME_EXTERNAL, selection, selectionArgs.toTypedArray())
      ?: error("MediaStore asset query failed")
    return getAssets(cursor)
      .mapNotNull { result -> (result as? AssetResult.ValidAsset)?.asset }
      .toList()
  }

  fun hashAssets(
    assetIds: List<String>,
    // allowNetworkAccess is only used on the iOS implementation
    @Suppress("UNUSED_PARAMETER") allowNetworkAccess: Boolean,
    callback: (Result<List<HashResult>>) -> Unit
  ) {
    if (assetIds.isEmpty()) {
      completeWhenActive(callback, Result.success(emptyList()))
      return
    }

    hashTask?.cancel()
    hashTask = CoroutineScope(Dispatchers.IO).launch {
      try {
        val results = assetIds.map { assetId ->
          async {
            hashSemaphore.withPermit {
              ensureActive()
              hashAsset(assetId)
            }
          }
        }.awaitAll()

        completeWhenActive(callback, Result.success(results))
      } catch (_: CancellationException) {
        completeWhenActive(
          callback, Result.failure(
            FlutterError(
              HASHING_CANCELLED_CODE,
              "Hashing operation was cancelled",
              null
            )
          )
        )
      } catch (e: Exception) {
        completeWhenActive(callback, Result.failure(e))
      }
    }
  }

  private suspend fun hashAsset(assetId: String): HashResult {
    return try {
      val digest = MessageDigest.getInstance("SHA-1")
      openOriginalStream(assetId).use { inputStream ->
        val buffer = ByteArray(HASH_BUFFER_SIZE)
        while (true) {
          val bytesRead = inputStream.read(buffer)
          if (bytesRead == -1) break
          currentCoroutineContext().ensureActive()
          digest.update(buffer, 0, bytesRead)
        }
      }

      HashResult(assetId, null, Base64.encodeToString(digest.digest(), Base64.NO_WRAP))
    } catch (e: CancellationException) {
      throw e
    } catch (e: SecurityException) {
      HashResult(assetId, "Permission denied accessing asset: ${e.message}", null)
    } catch (e: Exception) {
      HashResult(assetId, "Failed to hash asset: ${e.message}", null)
    }
  }

  private fun openOriginalStream(assetId: String): InputStream {
    val id = assetId.toLong()
    val collection = when (getMediaType(id)) {
      MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
      else -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    }
    val uri = ContentUris.withAppendedId(collection, id)
    val original = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.setRequireOriginal(uri)
    } else {
      uri
    }

    return ctx.contentResolver.openInputStream(original)
      ?: throw IOException("Cannot open original stream for asset $assetId")
  }

  private fun getMediaType(id: Long): Int =
    getCursor(
      MediaStore.VOLUME_EXTERNAL,
      "${MediaStore.MediaColumns._ID} = ?",
      arrayOf(id.toString()),
      arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE)
    )?.use { cursor ->
      if (cursor.moveToFirst()) {
        cursor.getInt(cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE))
      } else {
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
      }
    } ?: MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE

  fun cancelHashing() {
    hashTask?.cancel()
    hashTask = null
  }

  fun cancelSync() {
    syncJob?.cancel()
    syncJob = null
  }

  protected fun <T> runSync(callback: (Result<T>) -> Unit, work: suspend () -> T) {
    syncJob?.cancel()
    syncJob = CoroutineScope(Dispatchers.IO).launch {
      try {
        completeWhenActive(callback, Result.success(work()))
      } catch (_: CancellationException) {
        completeWhenActive(
          callback,
          Result.failure(FlutterError(SYNC_CANCELLED_CODE, "Sync cancelled", null))
        )
      } catch (e: Exception) {
        completeWhenActive(callback, Result.failure(e))
      }
    }
  }

  fun restoreFromTrashById(mediaId: String, type: Long, callback: (Result<Boolean>) -> Unit) {
    mediaTrashDelegate.restoreFromTrashById(mediaId, type) { completeWhenActive(callback, it) }
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    mediaTrashDelegate.onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    mediaTrashDelegate.onDetachedFromActivity()
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    mediaTrashDelegate.onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    mediaTrashDelegate.onDetachedFromActivity()
  }

  // This method is only implemented on iOS; on Android, we do not have a concept of cloud IDs
  @Suppress("unused", "UNUSED_PARAMETER")
  fun getCloudIdForAssetIds(assetIds: List<String>): List<CloudIdResult> {
    return emptyList()
  }

  fun getExistingAssetIds(assetIds: List<String>): List<String> {
    if (assetIds.isEmpty()) {
      return emptyList()
    }

    val existing = mutableListOf<String>()
    for (chunk in assetIds.chunked(SQLITE_MAX_VARIABLE_NUMBER)) {
      val placeholders = chunk.joinToString(",") { "?" }
      val queryArgs = Bundle().apply {
        putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns._ID} IN ($placeholders)")
        putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, chunk.toTypedArray())
        // Assets on an ejected volume are gone from the queries, but not deleted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
          putBoolean(MediaStore.QUERY_ARG_INCLUDE_RECENTLY_UNMOUNTED_VOLUMES, true)
        }
      }
      val cursor = ctx.contentResolver.query(
        MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
        arrayOf(MediaStore.MediaColumns._ID),
        queryArgs,
        null
      ) ?: error("MediaStore asset existence query failed")
      cursor.use {
        val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
        while (cursor.moveToNext()) {
          existing.add(cursor.getLong(idColumn).toString())
        }
      }
    }
    return existing
  }

  fun getAssetIdsBySize(sizes: List<Long>): Map<String, Long> {
    if (sizes.isEmpty()) {
      return emptyMap()
    }

    val result = mutableMapOf<String, Long>()
    val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE)
    for (chunk in sizes.distinct().chunked(SQLITE_MAX_VARIABLE_NUMBER)) {
      val placeholders = chunk.joinToString(",") { "?" }
      val cursor = getCursor(
        MediaStore.VOLUME_EXTERNAL,
        "$MEDIA_SELECTION AND ${MediaStore.MediaColumns.SIZE} IN ($placeholders)",
        arrayOf(*MEDIA_SELECTION_ARGS, *chunk.map { it.toString() }.toTypedArray()),
        projection
      ) ?: error("MediaStore asset size query failed")
      cursor.use {
        val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
        val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
        while (cursor.moveToNext()) {
          result[cursor.getLong(idColumn).toString()] = cursor.getLong(sizeColumn)
        }
      }
    }
    return result
  }
}
