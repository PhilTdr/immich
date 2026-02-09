## Description

<!--- Describe your changes in detail -->
<!--- Why is this change required? What problem does it solve? -->
<!--- If it fixes an open issue, please link to the issue here. -->

Version [2.3.0](https://github.com/immich-app/immich/discussions/24007) introduced the “Delete synchronization” feature ([#3594](https://github.com/immich-app/immich/discussions/3594)). This covers the synchronization direction Remote → Local.
This pull request adds the opposite direction, Local → Remote, to the synchronization of deleted items.

User story for this feature:
The user wants photos/videos that are deleted from the system gallery to also be deleted from Immich.

Implementation:
uring local synchronization, the system detects when a LocalAsset is no longer present on the device’s storage, indicating that it was deleted by an external app. In this case, the asset is also removed from Immich by moving it to the trash.

Issue:
I found this existing issue [#23070](https://github.com/immich-app/immich/discussions/23070) and it is also a step in the direction of [#4341](https://github.com/immich-app/immich/discussions/4341).

## How Has This Been Tested?

<!-- Please describe the tests that you ran to verify your changes. Provide instructions so we can reproduce. Please also list any relevant details for your test configuration -->

- Wrote Tests for new functions in Repositories and Services
  - new tests in local_sync_service_test.dart
  - new test in local_asset_repository_test.dart
- Testet by using the UI / deleting real assets

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
