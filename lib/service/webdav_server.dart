import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import 'package:vup/app.dart';
import 'package:vup/generic/state.dart';
import 'package:vup/service/base.dart';
import 'package:vup/service/web_server/serve_chunked_file.dart';
import 'package:vup/service/web_server/serve_plaintext_file.dart';

final esc = HtmlEscape();

class WebDavServerService extends VupService {
  bool isRunning = false;
  late Alfred app;

  final Map<String, Completer> filePutLocks = {};

  void stop() {
    info('stopping server...');
    app.close(force: true);
    isRunning = false;
    info('stopped server.');
  }

  void start(int port, String bindIp, String username, String password) {
    if (isRunning) return;
    isRunning = true;

    info('starting server...');

    app = Alfred();

    Map<String, String> getHeadersForFile(FileReference file) {
      final df = DateFormat('EEE, dd MMM yyyy HH:mm:ss');
      final dt = DateTime.fromMillisecondsSinceEpoch(file.modified).toUtc();
      final fileVersion = file.file;

      return {
        'Accept-Ranges': 'bytes',
        'Content-Type': file.mimeType ?? 'application/octet-stream',
        'Content-Length': fileVersion.cid.size.toString(),
        'Etag': '"${fileVersion.cid.hash.toBase64Url()}"',
        'Last-Modified': df.format(dt) + ' GMT',
      };
    }

    final df = DateFormat('EEE, dd MMM yyyy HH:mm:ss');

    final expectedAuthHeader =
        'Basic ' + base64.encode(utf8.encode('$username:$password'));

    app.all('*', (req, res) async {
      res.headers.add(
        'WWW-Authenticate',
        'Basic realm="skyfs", charset="UTF-8"',
      );

      /* res.headers.add(
        'DAV',
        '1, 3',
      ); */
      res.headers.add('date', '${df.format(DateTime.now().toUtc()) + ' GMT'}');

      if (req.headers.value('authorization') != expectedAuthHeader) {
        warning(
            'blocked, invalid auth (${req.method} ${req.requestedUri.toString()})');
        res.statusCode = 401;
        res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
        return '''<?xml version="1.0" encoding="utf-8"?>
<d:error
  xmlns:d="DAV:"
  xmlns:oc="http://owncloud.org/ns"
  xmlns:s="http://sabredav.org/ns">
  <s:exception>Sabre\\DAV\\Exception\\NotAuthenticated</s:exception>
  <s:message>No public access to this resource., No 'Authorization: Bearer' header found. Either the client didn't send one, or the server is mis-configured, No 'Authorization: Basic' header found. Either the client didn't send one, or the server is misconfigured</s:message>
</d:error>
''';
      }
      final method = req.method;

      if (method == 'PROPFIND') {
        dynamic body = await req.body;
        if (body is Uint8List) {
          body = (utf8.decode(body as Uint8List));
        }
        // logger.verbose(body);

        final props = RegExp(r'<d:prop>(.+)<\/d:prop>')
            .firstMatch(body.replaceAll('\n', ''))
            ?.group(1);

        res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');

        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();

        var path = pathSegments.join('/');

        verbose('path $path');

        // TODO Fix quota info
        if (props?.contains('quota-available-bytes') ?? false) {
          return '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus
  xmlns:d="DAV:"
  xmlns:oc="http://owncloud.org/ns">
 <d:response>
    <d:href>/${esc.convert(path)}/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>${df.format(DateTime.now().toUtc()) + ' GMT'}</d:getlastmodified>
        <d:resourcetype>
          <d:collection/>
        </d:resourcetype>
        <d:quota-used-bytes>1000000</d:quota-used-bytes>
        <d:quota-available-bytes>1000000000000</d:quota-available-bytes>
        <d:getetag>&quot;none&quot;</d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
        }

        String? filename;

        DirectoryMetadata? dirIndex;

        if (!req.requestedUri.path.endsWith('/')) {
          final p = storageService.dac.parseFilePath(path);
          dirIndex = await storageService.dac.getDirectoryMetadata(
            p.directoryPath,
          );
          if (!dirIndex.directories.containsKey(p.fileName)) {
            path = p.directoryPath;
            filename = p.fileName;
          } else {
            dirIndex = null;
          }
        }

        dirIndex ??= /* storageService.dac.getDirectoryMetadataCached(
              path,
            ) ?? */
            (await storageService.dac.getDirectoryMetadata(
          path,
        ));

        var str = '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus
  xmlns:d="DAV:"
  xmlns:oc="http://owncloud.org/ns"
  xmlns:x1="http://open-collaboration-services.org/ns">
''';

        /*   if (path == '') {
          logger.verbose('[webdav] detected empty path');
          str += '''  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Sat, 06 Nov 2021 19:13:23 GMT</d:getlastmodified>
        <d:resourcetype>
          <d:collection
            xmlns:d="DAV:"/>
          </d:resourcetype>
        </d:prop>
        <d:status>HTTP/1.1 200 OK</d:status>
      </d:propstat>
      <d:propstat>
        <d:prop>
          <d:getcontentlength></d:getcontentlength>
          <d:getcontenttype></d:getcontenttype>
          <d:getetag></d:getetag>
        </d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status>
      </d:propstat>
    </d:response>
''';
        } */
        if (filename == null) {
          str += '''
<d:response>
    <d:href>/${esc.convert(pathSegments.join('/'))}/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>${df.format(DateTime.now().toUtc()) + ' GMT'}</d:getlastmodified>
        <d:resourcetype>
          <d:collection/>
        </d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop>
          <d:displayname/>
          <oc:checksums/>
          <d:getcontentlength></d:getcontentlength>
          <d:getcontenttype></d:getcontenttype>
          <d:getetag></d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  ''';
        }

        /*  */

        if (req.headers.value('depth') != '0') {
          if (filename == null) {
            // final parentDir =

            for (final dir in dirIndex.directories.keys) {
              final href = [...pathSegments, dir];
              final uri = Uri(pathSegments: href);
              str += '''
<d:response>
    <d:href>/${esc.convert(uri.path)}/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>${df.format(DateTime.fromMillisecondsSinceEpoch(dirIndex.directories[dir]!.created).toUtc()) + ' GMT'}</d:getlastmodified>
        <d:resourcetype>
          <d:collection/>
        </d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop>
          <d:displayname/>
          <oc:checksums/>
          <d:getcontentlength></d:getcontentlength>
          <d:getcontenttype></d:getcontenttype>
          <d:getetag></d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>

  ''';
            }
          }
          for (final fileName in dirIndex.files.keys) {
            if (filename != null) {
              if (fileName != filename) continue;
            }

            final href = [...pathSegments, fileName];

            final uri = Uri(pathSegments: href);
            final file = dirIndex.files[fileName]!;

            final fileVersion = file.file;

            String checksum = '';
            // TODO Support checksums
            /*   for (final Multihash h in [
              file.file.hash,
              ...(file.file.hashes ?? [])
            ]) {
              if (h.startsWith('1220')) {
                checksum += ' SHA256:${h.substring(4)}';
              } else if (h.startsWith('1114')) {
                checksum += ' SHA1:${h.substring(4)}';
              }
            }
            checksum = checksum.trimLeft(); */

            str += '''
            <d:response>
    <d:href>/${esc.convert(uri.path)}</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>${df.format(DateTime.fromMillisecondsSinceEpoch(file.modified).toUtc()) + ' GMT'}</d:getlastmodified>
        <d:getcontentlength>${fileVersion.cid.size}</d:getcontentlength>
        <d:resourcetype/>
        <d:getetag>&quot;${fileVersion.cid.hash.toBase64Url()}&quot;</d:getetag>
        <d:getcontenttype>${file.mimeType ?? 'application/octet-stream'}</d:getcontenttype>
        <oc:checksums><oc:checksum>$checksum</oc:checksum></oc:checksums>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
      <d:propstat>
        <d:prop>
          <d:displayname/>        
        </d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status>
      </d:propstat>
    
  </d:response>
  
  ''';
          }
        } else {}

        str += '''
</d:multistatus>
''';
        res.statusCode = 207;

        return str;
      } else if (method == 'GET') {
        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();
        verbose('GET $pathSegments');

        final parsed = storageService.dac.parseFilePath(pathSegments.join('/'));

        final dirIndex = storageService.dac.getDirectoryMetadataCached(
              parsed.directoryPath,
            ) ??
            await storageService.dac.getDirectoryMetadata(
              parsed.directoryPath,
            );

        final file = dirIndex.files[parsed.fileName];

        if (file == null) {
          res.statusCode = HttpStatus.notFound;
          return '';
        }

        for (final e in getHeadersForFile(file).entries) {
          res.headers.set(e.key, e.value);
        }

        final localFile = storageService.getLocalFile(file);
        if (localFile != null) return localFile;

        if (file.file.encryptedCID == null) {
          return await handlePlaintextFile(req, res, file);
        } else if (file.file.encryptedCID?.encryptionAlgorithm ==
            encryptionAlgorithmXChaCha20Poly1305) {
          await handleChunkedFile(req, res, file, file.file.cid.size!);
          return null;
        } else {
          throw 'Encryption type not supported';
        }
      } else if (method == 'PUT') {
        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();
        final lockKey = pathSegments.join('/');
        if (filePutLocks.containsKey(lockKey)) {
          if (!filePutLocks[lockKey]!.isCompleted) {
            await filePutLocks[lockKey]!.future;
          }
          res.statusCode = HttpStatus.created;
          return '';
        }

        final modTime =
            req.headers['x-oc-mtime']?.first; // unix timestamp in seconds

        // TODO oc-checksum header

        filePutLocks[lockKey] = Completer();

        final parsed = storageService.dac.parseFilePath(pathSegments.join('/'));

        final cacheFile = File(
          join(
            storageService.temporaryDirectory,
            'webdav-cache',
            Uuid().v4(),
            parsed.fileName,
          ),
        );

        cacheFile.createSync(recursive: true);

        final sink = cacheFile.openWrite();
        await sink.addStream(req);

        await sink.flush();
        await sink.close();

        final DirectoryMetadata dirIndex;

        try {
          dirIndex = storageService.dac.getDirectoryMetadataCached(
                // TODO Check if this is ok
                parsed.directoryPath,
              ) ??
              (await storageService.dac.getDirectoryMetadata(
                parsed.directoryPath,
              ));
        } catch (e, st) {
          // TODO Create recursive
          rethrow;
          // await storageService.dac.createDirectory(path, name)
        }

        final fileData = await storageService.startFileUploadingTask(
            parsed.directoryPath, cacheFile,
            create: !dirIndex.files.containsKey(parsed.fileName),
            modified: modTime == null ? null : (int.parse(modTime) * 1000)
            // TODO encrypted: false,

            );
        verbose('[webdav] upload res $fileData');

        cacheFile.deleteSync();

        filePutLocks[lockKey]!.complete();
        filePutLocks.remove(lockKey);

        res.statusCode = HttpStatus.created;

        verbose('PUT done');

        return '';
      } else if (method == 'MKCOL') {
        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();

        final parsed = storageService.dac.parseFilePath(pathSegments.join('/'));

        final dirIndex = storageService.dac.getDirectoryMetadataCached(
              parsed.directoryPath,
            ) ??
            await storageService.dac.getDirectoryMetadata(
              parsed.directoryPath,
            );

        if (dirIndex.directories.containsKey(parsed.fileName)) {
          res.statusCode = HttpStatus.ok;
          return '';
        }

        await storageService.dac.createDirectory(
          pathSegments.sublist(0, pathSegments.length - 1).join('/'),
          pathSegments.last,
        );

        res.statusCode = HttpStatus.created;
        return '';
      } else if (method == 'DELETE') {
        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();
        if (req.requestedUri.path.endsWith('/')) {
          await storageService.dac.deleteDirectory(
            pathSegments.sublist(0, pathSegments.length - 1).join('/'),
            pathSegments.last,
          );
        } else {
          await storageService.dac.deleteFile(
            pathSegments.join('/'),
          );
        }

        res.statusCode = HttpStatus.noContent;
        return '';
      } else if (method == 'MOVE') {
        final pathSegments = req.requestedUri.pathSegments
            .where((element) => element.isNotEmpty)
            .toList();

        final destination = Uri.parse(req.headers['destination']!.first);

        final source = storageService.dac.parseFilePath(pathSegments.join('/'));
        final dest = storageService.dac
            .parseFilePath(destination.pathSegments.join('/'));

        if (source.directoryPath == dest.directoryPath) {
          final res = await storageService.dac.renameFile(
            pathSegments.join('/'),
            destination.pathSegments.lastWhere((element) => element.isNotEmpty),
          );
        } else {
          await storageService.dac.moveFile(
            pathSegments.join('/'),
            destination.pathSegments.join('/'),
          );
        }

        res.statusCode = HttpStatus.created;

        return '';
      }
    });

    info('server is running at $bindIp:$port');

    app.listen(port, bindIp);
    return;
  }
}
