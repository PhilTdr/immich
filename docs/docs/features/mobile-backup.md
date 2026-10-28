---
sidebar_position: 1
---

# Mobile Backup

## Overview

Immich supports uploading photos and videos from your mobile device to the server automatically.

When backup is enabled, Immich will upload new photos and videos from selected albums when you open or resume the app, as well as periodically in the background.

<img
src={require('./img/enable-backup-button.webp').default}
width="400px"
title="Upload button"
/>

## General Features

### Backup albums selection

<img
src={require('./img/backup-album-selection.webp').default}
width="400px"
title="Backup album selection"
/>

You can select which albums on your mobile device to back up to the server. You can also exclude specific albums (by double-tapping on them) from being backed up. This is useful for iOS users since assets can belong to multiple albums. For example, you may want to back up all assets except those in the "Videos" album.

### Deduplication

When you first select albums for backup, Immich calculates a checksum for each file's content. This checksum identifies assets already on the server—whether uploaded via CLI, web interface, or another device. Files matching existing assets are skipped, preventing duplicate uploads and saving bandwidth.

### Networking requirements

By default, Immich will only upload photos and videos when connected to Wi-Fi. You can change this behavior in the backup settings page.

<img
src={require('./img/backup-options.webp').default}
width="400px"
title="Upload button"
/>

### Backup album synchronization

<img
src={require('./img/backup-album-sync.webp').default}
width="400px"
title="Backup album synchronization option"
/>

When enabled, Immich automatically creates albums on the server that mirror the albums on your mobile device. Photos and videos are organized into these server-side albums to match your device's album structure, making it easy to find and browse your content the same way you do on your phone.

This is a one-way sync from your device to the server. You can enable this feature at any time and use the **Reorganize into album** button to backfill existing uploads into their corresponding albums.

### Sync deleted photos and videos

When **Deleted on device** is enabled in the backup settings, photos and videos that you delete in another app, such as the gallery, the iOS Photos app or a file manager, are also moved to the trash on the server. They are deleted permanently once the server empties its trash (after 30 days by default). The option is off by default and requires full access to the photo library.

- The app notices deletions when it syncs (when you open or resume the app, or in the background) and moves them to the server trash at the first sync that runs at least 15 minutes later. Until then, the **Deletions** card on the backup page lists them, and turning the option off cancels them. They also stay pending while the trash is disabled on the server.
- Only deletions made while the option is on are synced, and only for photos and videos in your own account. Photos and videos removed by Immich itself, for example with [Free Up Space](/features/mobile-app#free-up-space), are not moved to the server trash.
- If almost all backed-up photos disappear from the device at once, for example after you turn off iCloud Photos, these deletions are not synced. If fewer disappear, they are moved to the server trash, so turn this option off before you turn off iCloud Photos, sign out of iCloud or remove many photos from the device in another way.
- If you restore a deleted photo on the device while its server copy is still in the trash, the server copy is restored as well, as long as the option is still on and this device synced the deletion.
- On Android, moving a photo to another folder that is not backed up does not count as deleting it. Moving it somewhere other apps can't see, for example a folder with a `.nomedia` file or a locked folder of another app, does count. Turn on **Moved out of backup** to also sync moves that copy the photo to a new file, for example to the SD card, as deletions. Removing an SD card or USB drive does not count as deleting the photos on it.
- On iOS, deletions in iCloud shared albums are not synced, because photos there also disappear when another member removes them. Turn on **Deleted in iCloud shared albums** to sync them anyway, except for whole shared albums that disappear from the device. Turning that option off clears all pending deletions.
- If you use Immich on several devices, deleting a photo on one of them moves the server copy to the trash even if another device still has it. Other Android devices that have **Sync remote deletions** turned on in the advanced settings then also move their copy to the device trash.

:::warning Hidden photos on iOS
iOS locks the Hidden album by default, and while it is locked, apps can't see hidden photos. A backed-up photo that you hide therefore counts as deleted the next time the app starts and is moved to the server trash. To keep the server copy, restore it from the server trash before the trash is emptied.
:::

## Platform Specific Features

### Android

<img
src={require('./img/android-backup-options.webp').default}
width="400px"
title="Android backup options"
/>

- It is a well-known problem that some Android models are very strict with battery optimization settings, which can cause a problem with the background worker. Please visit [Don't kill my app](https://dontkillmyapp.com/) for a guide on disabling this setting on your phone.
- You can allow the background task to run only when the device is charging.
- You can set the minimum delay from the time a photo is taken to when the background upload task will run.

### iOS

- You must enable **Background App Refresh** for the app to work in the background. You can enable it in the Settings app under General > Background App Refresh.

<div style={{textAlign: 'center'}}>
<img src={require('./img/background-app-refresh.webp').default} width="30%" title="background-app-refresh" />
</div>

- iOS automatically manages background tasks; the app cannot control when the background upload task will run. The more frequently you open the app, the more often background tasks will run.

#### iCloud Backup

Local albums containing assets from iCloud and marked for backup in Immich will be pulled from iCloud and temporarily stored in the app's cache folder. Once the hashing and uploading process is completed, the temporary files will be emptied.

This process may consume additional data and storage space on your device, especially if you have a large number of iCloud photos and videos. Please ensure you have sufficient storage space and monitor your data usage if you are not connected to Wi-Fi.
