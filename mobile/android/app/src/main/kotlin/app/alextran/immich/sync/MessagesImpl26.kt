package app.alextran.immich.sync

import android.content.Context
import android.os.Environment
import android.os.storage.StorageManager


class NativeSyncApiImpl26(context: Context) : NativeSyncApiImplBase(context), NativeSyncApi {
  private val ctx: Context = context.applicationContext
  private val prefs = ctx.getSharedPreferences(SHARED_PREF_NAME, Context.MODE_PRIVATE)

  companion object {
    const val SHARED_PREF_NAME = "Immich::MediaManager"
    const val SHARED_PREF_VOLUMES_KEY = "StorageManager::mountedVolumes"
  }

  override fun shouldFullSync(callback: (Result<Boolean>) -> Unit) {
    runSync(callback) { shouldFullSync() }
  }

  private fun shouldFullSync(): Boolean {
    return true
  }

  override fun checkpointSync() {
    // Cannot throw exception as this is called from the Dart side
    // during the full sync process as well
    runCatching { prefs.edit().putStringSet(SHARED_PREF_VOLUMES_KEY, getMountedVolumes()).apply() }
  }

  override fun clearSyncCheckpoint() {
    // No-op for Android 10 and below
  }

  override fun getMediaChanges(callback: (Result<SyncDelta>) -> Unit) {
    runSync(callback) { getMediaChanges() }
  }

  private fun getMediaChanges(): SyncDelta {
    throw IllegalStateException("Method not supported on this Android version.")
  }

  override fun getTrashedAssets(): Map<String, List<PlatformAsset>> {
    //Method not supported on this Android version.
    return emptyMap()
  }

  override fun getExistingAssetIds(assetIds: List<String>): List<String> {
    // A volume that was mounted at the last sync and is missing now was ejected, its assets are not deleted
    val lastMounted = prefs.getStringSet(SHARED_PREF_VOLUMES_KEY, null).orEmpty()
    if (!getMountedVolumes().containsAll(lastMounted)) {
      return assetIds
    }
    return super.getExistingAssetIds(assetIds)
  }

  private fun getMountedVolumes(): Set<String> =
    ctx.getSystemService(StorageManager::class.java)?.storageVolumes.orEmpty()
      .filter { it.state == Environment.MEDIA_MOUNTED }
      .map { it.uuid ?: "primary" }
      .toSet()
}
