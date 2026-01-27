import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart' as s;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:mime/mime.dart';

late Directory baseDir;
late String serverUrl;
HttpServer? server;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  print("🚀 WiFiShare Server Starting...");

  // 📁 Select base folder
  final String? path = await getDirectoryPath(
    confirmButtonText: "Select WiFiShare Folder",
  );

  if (path == null) {
    print("❌ No folder selected. Exiting.");
    exit(0);
  }

  baseDir = Directory(path);
  print("📁 Base directory: ${baseDir.path}");

  await startServer();

  runApp(const MyApp());
}

Future<void> startServer() async {
  final router = s.Router();

  // ==============================
  // ANDROID → WINDOWS (UPLOAD)
  // ==============================
  router.post('/android-send', (Request req) async {
    try {
      final uploadDir = Directory('${baseDir.path}/from_android');
      await uploadDir.create(recursive: true);

      final contentType = req.headers['content-type'];
      if (contentType == null || !contentType.contains('multipart/form-data')) {
        return Response.badRequest(body: "Invalid multipart request");
      }

      final boundary = contentType.split('boundary=').last;
      final parts =
      await MimeMultipartTransformer(boundary).bind(req.read()).toList();

      for (final part in parts) {
        final cd = part.headers['content-disposition'];
        final match =
        RegExp(r'filename="(.+)"').firstMatch(cd ?? '');
        final filename = match?.group(1);

        if (filename != null) {
          final file = File('${uploadDir.path}/$filename');
          await part.pipe(file.openWrite());
          print("📥 Received: $filename");
        }
      }

      return Response.ok("File received");
    } catch (e) {
      print("❌ Upload error: $e");
      return Response.internalServerError(body: "Upload failed");
    }
  });

  // ==============================
  // WINDOWS → ANDROID (DOWNLOAD)
  // ==============================
  router.get('/windows-send', (Request req) async {
    try {
      final sendDir = Directory('${baseDir.path}/to_android');
      if (!await sendDir.exists()) {
        return Response.notFound("No file available");
      }

      final files = await sendDir.list().toList();
      if (files.isEmpty) {
        return Response.notFound("No file available");
      }

      final file = files.first as File;
      final bytes = await file.readAsBytes();
      final filename = file.uri.pathSegments.last;
      final mimeType =
          lookupMimeType(filename) ?? 'application/octet-stream';

      await file.delete();

      print("📤 Sent to Android: $filename");

      return Response.ok(
        bytes,
        headers: {
          HttpHeaders.contentTypeHeader: mimeType,
          'content-disposition': 'attachment; filename="$filename"',
        },
      );

    } catch (e) {
      print("❌ Download error: $e");
      return Response.internalServerError(body: "Download failed");
    }
  });

  // 🔌 Start server
  server = await io.serve(router.call, InternetAddress.anyIPv4, 0);

  final ip = await getLocalIp();
  serverUrl = "http://$ip:${server!.port}";

  print("🌐 Server running at $serverUrl");
}

// ==============================
// GET LOCAL IP (Windows-safe)
// ==============================
Future<String> getLocalIp() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );

  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    if (name.contains('virtual') ||
        name.contains('vmnet') ||
        name.contains('vbox') ||
        name.contains('docker')) continue;

    for (final addr in interface.addresses) {
      return addr.address;
    }
  }

  return "127.0.0.1";
}

// ==============================
// UI
// ==============================
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String status = "Waiting for files from Android...";

  Future<void> sendToAndroid() async {
    final XFile? file = await openFile();
    if (file == null) return;

    final dir = Directory('${baseDir.path}/to_android');
    await dir.create(recursive: true);

    final files = await dir.list().toList();
    for (final f in files) {
      await f.delete();
    }

    await File(file.path).copy('${dir.path}/${file.name}');

    setState(() {
      status = "📤 Ready to send: ${file.name}";
    });
  }

  Future<void> checkReceived() async {
    final dir = Directory('${baseDir.path}/from_android');
    if (!await dir.exists()) {
      setState(() => status = "No files received");
      return;
    }

    final files = await dir.list().toList();
    if (files.isEmpty) {
      setState(() => status = "No files received");
      return;
    }

    final name = files.first.path.split(Platform.pathSeparator).last;
    setState(() => status = "📥 Received: $name");
  }

  @override
  void dispose() {
    server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WiFiShare Server',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('WiFiShare Server'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrImageView(
                  data: serverUrl,
                  size: 220,
                ),
                const SizedBox(height: 16),
                Text(
                  serverUrl,
                  textAlign: TextAlign.center,
                  style:
                  const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: sendToAndroid,
                  icon: const Icon(Icons.send),
                  label: const Text("Select File → Send to Android"),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: checkReceived,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Check Received Files"),
                ),
                const SizedBox(height: 24),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
