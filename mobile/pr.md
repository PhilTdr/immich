## Description

<!--- Describe your changes in detail -->
<!--- Why is this change required? What problem does it solve? -->
<!--- If it fixes an open issue, please link to the issue here. -->

Version [2.3.0](https://github.com/immich-app/immich/discussions/24007) introduced the “Delete synchronization” feature ([#3594](https://github.com/immich-app/immich/discussions/3594)). This covers the synchronization direction Remote → Local.
This pull request adds the opposite direction, Local → Remote, to the synchronization of deleted items.

User story for this feature:
The user wants photos/videos that are deleted from the system gallery to also be deleted from Immich, and when such a photo/video reappears on the device it should also be restored on the server.

Implementation:
During local synchronization the app uses the native media changes (and the full sync) to detect which already backed-up assets were deleted from the device. Those assets are moved to the trash on the server, so they are only soft deleted and stay restorable. A small local table keeps these pending deletions as a per-account queue, so a move-to-trash that has not yet reached the server (for example while offline) is retried on a later sync and is not lost when logging out and back in.

The opposite case, restoring, is derived from the synchronized state rather than from that table: whenever an asset is present on the device again but its backed-up counterpart still sits in the trash on the server, it is restored. Matching is done per user via the checksum, so partner or shared assets are never affected. Because the device is treated as the source of truth here, this also restores assets after the app data was cleared or the app was reinstalled, and it will bring back an asset that was trashed elsewhere (for example on the web) while a copy still exists on the device. The feature is off by default and can be turned on in the backup settings.

Issue:
I found this existing issue [#23070](https://github.com/immich-app/immich/discussions/23070) and it is also a step in the direction of [#4341](https://github.com/immich-app/immich/discussions/4341).

## How Has This Been Tested?

<!-- Please describe the tests that you ran to verify your changes. Provide instructions so we can reproduce. Please also list any relevant details for your test configuration -->

- Wrote Tests for new functions in Repositories and Services
  - new tests in local_sync_service_test.dart
  - new tests in local_asset_repository_test.dart
  - new tests in local_deletion_repository_test.dart
  - new tests in remote_asset_repository_test.dart
  - new tests in auth_repository_test.dart
- The new database table is covered by the generated drift migration test
- Testet by using the UI / deleting and restoring real assets on the device

<details><summary><h2>Screenshots (if appropriate)</h2></summary>

<!-- Images go below this line. -->

</details>

## Checklist:

- [x] I have performed a self-review of my own code
- [ ] I have made corresponding changes to the documentation if applicable
- [x] I have no unrelated changes in the PR.
- [x] I have confirmed that any new dependencies are strictly necessary.
- [x] I have written tests for new code (if applicable)
- [x] I have followed naming conventions/patterns in the surrounding code
- [x] All code in `src/services/` uses repositories implementations for database calls, filesystem operations, etc.
- [x] All code in `src/repositories/` is pretty basic/simple and does not have any immich specific logic (that belongs in `src/services/`)

## Please describe to which degree, if any, an LLM was used in creating this pull request.

No LLM used
