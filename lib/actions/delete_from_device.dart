import 'dart:io';

import 'package:filesystem_dac/dac.dart';
import 'package:path/path.dart';
import 'package:vup/app.dart';

import 'base.dart';

class DeleteFromDeviceVupAction extends VupFSAction {
  @override
  VupFSActionInstance? check(
      bool isFile,
      dynamic entity,
      PathNotifierState pathNotifier,
      BuildContext context,
      bool isDirectoryView,
      bool hasWriteAccess,
      FileState fileState,
      bool isSelected) {
    if (isDirectoryView) return null;
    if (!isFile) return null;
    if (entity == null) return null;
    if (fileState.type != FileStateType.idle) return null;

    if (isSelected) {
      int availableOfflineCount = 0;

      for (final uri in pathNotifier.selectedFiles) {
        final path = storageService.dac.parseFilePath(uri);
        final dirIndex = storageService.dac.getDirectoryMetadataCached(
          path.directoryPath,
        );
        final file = dirIndex?.files[path.fileName];
        if (file == null) continue;

        if (localFiles.contains(file.file.cid.hash.fullBytes)) {
          availableOfflineCount++;
        }
      }
      if (availableOfflineCount == 0) return null;
      return VupFSActionInstance(
        label:
            'Delete $availableOfflineCount local ${availableOfflineCount == 1 ? 'copy' : 'copies'}',
        icon: UniconsLine.cloud_times,
      );
    } else {
      bool isAvailableOffline =
          localFiles.contains(entity.file.cid.hash.fullBytes);
      if (!isAvailableOffline) return null;
      return VupFSActionInstance(
        label: 'Delete local copy',
        icon: UniconsLine.cloud_times,
      );
    }
  }

  @override
  Future execute(
    BuildContext context,
    VupFSActionInstance instance,
  ) async {
    final files = <FileReference>[];
    if (instance.isSelected) {
      for (final uri in instance.pathNotifier.selectedFiles) {
        final path = storageService.dac.parseFilePath(uri);
        final di =
            storageService.dac.getDirectoryMetadataCached(path.directoryPath);
        files.add(di!.files[path.fileName]!);
      }
    } else {
      files.add(instance.entity);
    }
    for (final file in files) {
      final hash = file.file.cid.hash;
      try {
        final decryptedFile = File(join(
          storageService.dataDirectory,
          'local_files',
          hash.toBase32(),
          file.name,
        ));
        await decryptedFile.delete();
      } catch (_) {}
      localFiles.delete(hash.fullBytes);
      storageService.dac.getFileStateChangeNotifier(hash).updateFileState(
            FileState(
              type: FileStateType.idle,
              progress: null,
            ),
          );
    }
  }
}
