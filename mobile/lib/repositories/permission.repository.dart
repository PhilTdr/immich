import 'package:device_info_plus/device_info_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:permission_handler/permission_handler.dart';

final permissionRepositoryProvider = Provider((ref) {
  return PermissionRepository(ref.watch(permissionApiProvider));
});

class PermissionRepository implements IPermissionRepository {
  final PermissionApi _permissionApi;

  const PermissionRepository(this._permissionApi);

  @override
  Future<bool> hasLocationWhenInUsePermission() {
    return Permission.locationWhenInUse.isGranted;
  }

  @override
  Future<bool> requestLocationWhenInUsePermission() async {
    final result = await Permission.locationWhenInUse.request();
    return result.isGranted;
  }

  @override
  Future<bool> hasLocationAlwaysPermission() {
    return Permission.locationAlways.isGranted;
  }

  @override
  Future<bool> requestLocationAlwaysPermission() async {
    final result = await Permission.locationAlways.request();
    return result.isGranted;
  }

  @override
  Future<bool> openSettings() {
    return openAppSettings();
  }

  /// Full (not limited/selected) photo library access. Limited access hides
  /// assets from the media queries and must not be mistaken for deletions.
  @override
  Future<bool> hasFullMediaPermission() async {
    if (CurrentPlatform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt <= 32) {
        return (await Permission.storage.status).isGranted;
      }
      final photos = await Permission.photos.status;
      final videos = await Permission.videos.status;
      return photos.isGranted && videos.isGranted;
    }
    return (await Permission.photos.status).isGranted;
  }

  @override
  Future<bool> hasManageMediaPermission() {
    return _permissionApi.hasManageMediaPermission();
  }

  @override
  Future<bool> requestManageMediaPermission() {
    return _permissionApi.requestManageMediaPermission();
  }

  @override
  Future<bool> manageMediaPermission() {
    return _permissionApi.manageMediaPermission();
  }
}

abstract interface class IPermissionRepository {
  Future<bool> hasLocationWhenInUsePermission();
  Future<bool> requestLocationWhenInUsePermission();
  Future<bool> hasLocationAlwaysPermission();
  Future<bool> requestLocationAlwaysPermission();
  Future<bool> openSettings();
  Future<bool> hasFullMediaPermission();
  Future<bool> hasManageMediaPermission();
  Future<bool> requestManageMediaPermission();
  Future<bool> manageMediaPermission();
}
