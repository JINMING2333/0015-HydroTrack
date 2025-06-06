// lib/screens/pose_compare_page.dart

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:video_player/video_player.dart';
import '../models/standard_pose_model.dart';
import '../models/compare_painter.dart';
import '../models/pose_normalizer.dart';
import '../models/exercise.dart';
import '../services/supabase_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/exercise_data_service.dart';
import '../services/exercise_history_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

late List<CameraDescription> cameras;

class PoseComparePage extends StatefulWidget {
  final String? exerciseId;
  final String? name;
  final int? level;
  
  const PoseComparePage({
    Key? key, 
    this.exerciseId,
    this.name,
    this.level,
  }) : super(key: key);

  @override
  State<PoseComparePage> createState() => _PoseComparePageState();
}

class _PoseComparePageState extends State<PoseComparePage> {
  CameraController? _cameraController;
  CameraDescription? _cameraDescription;
  VideoPlayerController? _videoController;
  bool _initialized = false;
  bool _showStandardPose = true;
  Exercise? _currentExercise;
  final SupabaseService _supabase = SupabaseService();
  final ExerciseDataService _exerciseDataService = ExerciseDataService();
  final ExerciseHistoryService _exerciseHistoryService = ExerciseHistoryService();
  
  // 添加缺失的变量
  int _trainingDuration = 0;  // 训练时长（秒）
  String? _capturedImagePath;  // 捕获的图像路径
  DateTime? _startTime;  // 训练开始时间
  bool _hasStartedExercise = false;  // 添加标记，记录是否开始运动

  final _poseDetector = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
  );

  List<StandardPose> _standardPoses = [];
  Pose? _userPose;
  bool _isBusy = false;
  double _matchScore = 0.0;
  final double _threshold = 0.1;

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();  // 记录开始时间
    Future.microtask(_loadResources);
    
    // 添加视频完成监听
    _videoController?.addListener(_onVideoProgress);
  }

  Future<void> _loadResources() async {
    try {
      // 1. 获取练习数据
      if (widget.exerciseId != null) {
        final exercises = await _supabase.getExercises();
        final exerciseData = exercises.firstWhere(
          (e) => e['id'] == widget.exerciseId,
          orElse: () => throw Exception('Exercise not found: ${widget.exerciseId}'),
        );
        _currentExercise = Exercise.fromJson(exerciseData);
        debugPrint('加载运动: ${_currentExercise?.name}');
      }

      if (_currentExercise == null) {
        throw Exception('Exercise not found');
      }

      // 2. 加载JSON文件
      debugPrint('开始加载JSON文件: ${_currentExercise!.jsonUrl}');
      final jsonContent = await _supabase.getJsonContent(_currentExercise!.jsonUrl);
      final jsonData = json.decode(jsonContent);
      _standardPoses = StandardPose.fromJsonList(jsonData);
      debugPrint('成功加载标准姿势数据，数量: ${_standardPoses.length}');

      // 3. 初始化相机
      cameras = await availableCameras();
      _cameraDescription = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(
        _cameraDescription!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
      );
      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_processCameraImage);

      // 4. 初始化视频
      final videoUrl = await _supabase.getVideoUrl(_currentExercise!.videoUrl);
      debugPrint('加载视频: $videoUrl');
      _videoController = VideoPlayerController.network(videoUrl);
      await _videoController!.initialize();
      _videoController!.addListener(() {
        if (mounted) setState(() {});
      });
    } catch (e, st) {
      debugPrint('🔴 资源加载失败: $e\n$st');
    } finally {
      if (mounted) setState(() => _initialized = true);
    }
  }

  /// 拼接所有 plane 的 bytes
  Uint8List _concatenatePlanes(CameraImage image) {
    final builder = BytesBuilder();
    for (final plane in image.planes) {
      builder.add(plane.bytes);
    }
    return builder.toBytes();
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      debugPrint('\n===== 开始处理图像帧 =====');
      debugPrint('图像基本信息:');
      debugPrint('- 分辨率: ${image.width}x${image.height}');
      debugPrint('- 格式代码: ${image.format.raw}');
      debugPrint('- 平面数量: ${image.planes.length}');

      // 1. 拼平面
      final bytes = image.planes.first.bytes;
      debugPrint('图像数据:');
      debugPrint('- Y平面大小: ${bytes.length}');
      debugPrint('- 前10个像素值: ${bytes.take(10).toList()}');

      // 2. 构造 planeData
      final planeData = <InputImagePlaneMetadata>[
        InputImagePlaneMetadata(
          bytesPerRow: image.planes.first.bytesPerRow,
          height: image.height,
          width: image.width,
        ),
      ];

      // 3. 构造 InputImage
      final rotation = InputImageRotationValue.fromRawValue(
            _cameraDescription!.sensorOrientation,
          ) ??
          InputImageRotation.rotation0deg;
      final format = InputImageFormatValue.fromRawValue(image.format.raw)!;

      debugPrint('相机配置:');
      debugPrint('- 传感器方向: ${_cameraDescription!.sensorOrientation}°');
      debugPrint('- 使用旋转值: $rotation');
      debugPrint('- 镜头方向: ${_cameraDescription!.lensDirection}');
      debugPrint('- 图像格式: $format');

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        inputImageData: InputImageData(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          imageRotation: rotation,
          inputImageFormat: format,
          planeData: planeData,
        ),
      );

      debugPrint('\n开始姿势检测...');
      final startTime = DateTime.now();
      final poses = await _poseDetector.processImage(inputImage);
      final endTime = DateTime.now();
      final processingTime = endTime.difference(startTime).inMilliseconds;
      
      debugPrint('检测完成:');
      debugPrint('- 处理时间: ${processingTime}ms');
      debugPrint('- 检测到姿势: ${poses.length}个');

      if (poses.isNotEmpty) {
        final pose = poses.first;
        final landmarks = pose.landmarks;
        debugPrint('\n姿势详情:');
        debugPrint('- 关键点数量: ${landmarks.length}');
        
        // 检查关键点
        final hasNose = landmarks.containsKey(PoseLandmarkType.nose);
        final hasLeftShoulder = landmarks.containsKey(PoseLandmarkType.leftShoulder);
        final hasRightShoulder = landmarks.containsKey(PoseLandmarkType.rightShoulder);
        
        debugPrint('主要关键点:');
        debugPrint('- 鼻子: ${hasNose ? "已检测" : "未检测"}');
        debugPrint('- 左肩: ${hasLeftShoulder ? "已检测" : "未检测"}');
        debugPrint('- 右肩: ${hasRightShoulder ? "已检测" : "未检测"}');

        if (landmarks.isNotEmpty) {
          debugPrint('\n部分关键点坐标:');
          landmarks.entries.take(3).forEach((entry) {
            final point = entry.value;
            debugPrint('- ${entry.key.name}: '
                'x=${point.x.toStringAsFixed(1)}, '
                'y=${point.y.toStringAsFixed(1)}, '
                'z=${point.z.toStringAsFixed(1)}');
          });
        }

        setState(() {
          _userPose = pose;
          // 计算匹配得分
          _matchScore = _calculateMatchScore(pose, _getStandardPose());
        });
      } else {
        debugPrint('⚠️ 未检测到任何姿势');
      }

      debugPrint('===== 图像处理完成 =====\n');
    } catch (e, st) {
      debugPrint('❌ 处理出错: $e\n$st');
    } finally {
      _isBusy = false;
    }
  }

  /// 获取当前应该匹配的标准姿势
  StandardPose _getStandardPose() {
    if (_standardPoses.isEmpty || _videoController == null) {
      return _standardPoses.isNotEmpty ? _standardPoses.first : StandardPose.empty();
    }
    
    final posMs = _videoController!.value.position.inMilliseconds;
    
    // 直接寻找最匹配的标准姿势
    // 1. 首先检查是否超出范围
    if (posMs <= 0) {
      return _standardPoses.first;
    }
    
    final lastTimestampMs = (_standardPoses.last.timestamp * 1000).toInt();
    if (posMs >= lastTimestampMs) {
      return _standardPoses.last;
    }
    
    // 2. 使用二分查找找到最接近的时间戳
    int left = 0;
    int right = _standardPoses.length - 1;
    
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final midTimeMs = (_standardPoses[mid].timestamp * 1000).toInt();
      
      if (midTimeMs == posMs) {
        return _standardPoses[mid];
      } else if (midTimeMs < posMs) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    
    // 此时 left > right，找到了最接近的两个时间点
    // 如果right是-1，说明时间比第一帧还小，返回第一帧
    if (right < 0) {
      return _standardPoses.first;
    }
    
    // 如果left已经超出最后一帧，返回最后一帧
    if (left >= _standardPoses.length) {
      return _standardPoses.last;
    }
    
    // 比较哪个时间点更接近当前时间
    final rightTimeMs = (_standardPoses[right].timestamp * 1000).toInt();
    final leftTimeMs = (_standardPoses[left].timestamp * 1000).toInt();
    
    // 返回更接近的一个
    return (posMs - rightTimeMs) < (leftTimeMs - posMs) 
        ? _standardPoses[right] 
        : _standardPoses[left];
  }
  
  /// 计算用户姿势与标准姿势的匹配度（50-100分）
  double _calculateMatchScore(Pose userPose, StandardPose standardPose) {
    if (_cameraController == null || _cameraController!.value.previewSize == null) {
      return 50.0;
    }
    
    // 获取相机预览尺寸
    final previewSize = _cameraController!.value.previewSize!;
    final imageSize = Size(
      previewSize.height, // 注意这里是旋转90度后的尺寸
      previewSize.width
    );
    
    // 定义关键点及其权重 - 设置了更精细的权重分配
    final keyPoints = {
      // 上半身核心部位（权重更高）
      PoseLandmarkType.leftShoulder: 2.0,
      PoseLandmarkType.rightShoulder: 2.0,
      PoseLandmarkType.leftElbow: 1.8,
      PoseLandmarkType.rightElbow: 1.8,
      PoseLandmarkType.leftWrist: 1.5,
      PoseLandmarkType.rightWrist: 1.5,
      
      // 躯干（中等权重）
      PoseLandmarkType.leftHip: 1.5,
      PoseLandmarkType.rightHip: 1.5,
      
      // 下半身（权重稍低，因为在很多动作中下半身可能不是焦点）
      PoseLandmarkType.leftKnee: 1.2,
      PoseLandmarkType.rightKnee: 1.2,
      PoseLandmarkType.leftAnkle: 1.0,
      PoseLandmarkType.rightAnkle: 1.0,
    };
    
    // 使用PoseNormalizer归一化用户姿势
    final normalizedUserPose = PoseNormalizer.normalizeUserPose(userPose, imageSize);
    
    // 计算姿势相似度
    double score = PoseNormalizer.calculatePoseSimilarity(
      normalizedUserPose, 
      standardPose.landmarks, 
      keyPoints
    );
    
    // 将原始相似度（0-100）映射到更合理的分数范围（50-100）
    score = 50.0 + (score * 0.5);  // 将原始分数(0-100)映射到50-100区间
    score = score.clamp(50.0, 100.0); // 确保分数在50-100之间
    
    // 输出详细信息
    debugPrint('原始相似度: $score');
    debugPrint('最终得分: $score');
    
    return score;
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onVideoProgress);
    _cameraController?.dispose();
    _videoController?.dispose();
    _poseDetector.close();
    
    // 如果已经开始运动，则在退出时保存记录
    if (_hasStartedExercise && _startTime != null) {
      _trainingDuration = DateTime.now().difference(_startTime!).inSeconds;
      // 确保运动时长至少为1秒
      if (_trainingDuration > 0) {
        _onExerciseComplete();
      }
    }
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _videoController == null ||
        !_videoController!.value.isInitialized ||
        _standardPoses.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.name != null ? '${widget.name} - Level ${widget.level}' : 'Pose 比对'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name != null ? '${widget.name} - Level ${widget.level}' : 'Pose 比对'),
        actions: [
          TextButton(
            onPressed: () => _onExerciseComplete(),
            child: const Text(
              '完成',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _cameraPreview(),
                if (_userPose != null)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        children: [
                          // 半透明黑色背景，使骨骼线条更加明显
                          Container(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            color: Colors.black.withOpacity(0.2),
                          ),
                          // 只绘制用户姿势的骨骼线条
                          CustomPaint(
                            size: Size(constraints.maxWidth, constraints.maxHeight),
                            painter: ComparePainter(
                              userPose: _userPose!,
                              standardPose: _getStandardPose(),
                              imageSize: Size(
                                _cameraController!.value.previewSize?.height ?? 640.0,
                                _cameraController!.value.previewSize?.width ?? 480.0,
                              ),
                              showStandardPose: false,  // 不显示标准姿势的骨骼线条
                            ),
                          ),
                          // 检测状态灰色半透明模块，固定在左上角
                          Positioned(
                            left: 10,
                            top: 10,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              constraints: const BoxConstraints(maxWidth: 200),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Detection Status: ${_userPose != null ? "Detected" : "Not Detected"}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  if (_userPose != null) Text(
                                    'Keypoints: ${_userPose!.landmarks.length}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  if (_userPose != null) Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 5),
                                      Text(
                                        'Match Score: ${_matchScore.toStringAsFixed(1)}',
                                        style: TextStyle(
                                          color: _getScoreColor(_matchScore),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 18,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      LinearProgressIndicator(
                                        value: _matchScore / 100,
                                        backgroundColor: Colors.grey[700],
                                        valueColor: AlwaysStoppedAnimation<Color>(_getScoreColor(_matchScore)),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        _getScoreFeedback(_matchScore),
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: Stack(
                children: [
                  VideoPlayer(_videoController!),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        'Standard Demo: ${((_videoController!.value.position.inMilliseconds / (_videoController!.value.duration.inMilliseconds == 0 ? 1 : _videoController!.value.duration.inMilliseconds)) * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _videoController!.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            if (_videoController!.value.isPlaying) {
                              _videoController!.pause();
                            } else {
                              // 开始播放时标记开始运动
                              setState(() {
                                _hasStartedExercise = true;
                                // 重置开始时间
                                _startTime = DateTime.now();
                              });
                              _videoController!.play();
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.replay, color: Colors.white),
                          onPressed: () {
                            // 重新开始时也重置开始时间
                            setState(() {
                              _hasStartedExercise = true;
                              _startTime = DateTime.now();
                            });
                            _videoController!.seekTo(Duration.zero);
                            _videoController!.play();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  /// 根据分数返回不同颜色
  Color _getScoreColor(double score) {
    if (score >= 85) return Colors.green;
    if (score >= 70) return Colors.yellow;
    return Colors.orange;
  }
  
  /// 根据分数返回反馈文字
  String _getScoreFeedback(double score) {
    if (score >= 85) return "Perfect form!";
    if (score >= 75) return "Good form";
    if (score >= 70) return "Acceptable form";
    return "Keep adjusting your form";
  }

  Widget _cameraPreview() {
    return LayoutBuilder(
      builder: (context, constraints) {
        debugPrint('\n===== 相机预览布局信息 =====');
        debugPrint('Stack 约束: ${constraints.toString()}');
        debugPrint('相机预览尺寸: ${_cameraController!.value.previewSize}');
        debugPrint('相机预览比例: ${_cameraController!.value.aspectRatio}');
        
        // 计算适合的尺寸
        final size = _cameraController!.value.previewSize!;
        final deviceRatio = constraints.maxWidth / constraints.maxHeight;
        final previewRatio = size.height / size.width; // 注意这里交换了宽高
        
        // 根据宽高比计算最终尺寸
        final scale = deviceRatio < previewRatio 
            ? constraints.maxWidth / size.height
            : constraints.maxHeight / size.width;
        
        final previewW = size.height * scale;
        final previewH = size.width * scale;
        
        debugPrint('计算后的预览尺寸: ${previewW}x${previewH}');
        
        return Center(
          child: SizedBox(
            width: previewW,
            height: previewH,
            child: ClipRect(
              child: Transform.scale(
                scale: 1.0,
                child: Center(
                  child: CameraPreview(_cameraController!),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveExerciseHistory({
    required String exerciseName,
    required double score,
    required int duration,
    required String level,
    String? imageUrl,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      debugPrint('开始保存运动记录...');
      // 保存到本地数据库
      await _exerciseHistoryService.saveExerciseHistory(
        exerciseId: DateTime.now().millisecondsSinceEpoch.toString(),
        exerciseName: exerciseName,
        duration: duration,
        score: score,
        imageUrl: imageUrl ?? '',
        level: level,
        additionalData: additionalData ?? {},
        timestamp: DateTime.now().toIso8601String(),
      );
      debugPrint('✅ 本地保存成功');

      // 保存到 Firebase
      try {
        await _exerciseDataService.saveExerciseRecord(
          exerciseId: widget.exerciseId ?? 'unknown',
          exerciseName: widget.name ?? 'Unknown Exercise',
          duration: duration,
          score: score,
          imageUrl: imageUrl ?? '',
          level: int.tryParse(level) ?? 1,
          additionalData: additionalData ?? {},
        );
        debugPrint('✅ Firebase保存成功');
      } catch (firebaseError) {
        debugPrint('❌ Firebase保存失败: $firebaseError');
        // Firebase保存失败不影响整体流程
      }
    } catch (e) {
      debugPrint('❌ 保存运动记录失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存运动记录时出现错误')),
        );
      }
    }
  }

  // 修改保存方法，使其返回Future<void>
  Future<void> _onExerciseComplete() async {
    if (!_hasStartedExercise) return;  // 如果没有开始运动，不保存记录
    
    await _saveExerciseHistory(
      exerciseName: widget.name ?? 'Unknown Exercise',
      score: _matchScore,
      duration: _trainingDuration,
      level: widget.level?.toString() ?? '标准',
      imageUrl: _capturedImagePath,
      additionalData: {
        'landmarks': _userPose?.landmarks.map((k, v) => MapEntry(k.name, {
          'x': v.x,
          'y': v.y,
          'z': v.z,
        })),
        'standard_pose': _getStandardPose().landmarks.map((k, v) => MapEntry(k.name, {
          'x': v.x,
          'y': v.y,
          'z': v.z,
        })),
      },
    );

    if (mounted) {
      // 显示完成提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('运动记录已保存')),
      );
    }
  }

  void _onVideoProgress() {
    if (_videoController == null) return;
    
    // 检查视频是否播放完成
    if (_videoController!.value.position >= _videoController!.value.duration) {
      _onExerciseComplete();
      // 视频播放完成后，返回上一页
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }
}