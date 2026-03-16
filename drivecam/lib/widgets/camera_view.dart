import 'package:camera/camera.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class CameraView extends StatefulWidget {
  final CameraDescription camera;
  const CameraView({super.key, required this.camera});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.medium);

    // this passes a pointer of the camera controller, NOT a copy, so no state duplication is happening
    final provider = context.read<RecordingProvider>();
    _initializeControllerFuture = _controller.initialize().then((_) {
      provider.setCameraController(_controller);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller.value.previewSize?.height ?? 1,
                height: _controller.value.previewSize?.width ?? 1,
                child: CameraPreview(_controller),
              ),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
