import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../data/models/message_model.dart';
import '../../../data/services/api_service.dart';
import '../../../core/utils/media_utils.dart';
import '../../../core/utils/app_locale.dart';
import '../../screens/media/photo_viewer_screen.dart';
import '../media/voice_message_player.dart';
import '../media/media_labels.dart';
import 'file_message_bubble.dart';

class SharedMediaSection extends StatefulWidget {
  final String chatId;
  final ApiService api;
  final String? token;

  const SharedMediaSection({
    super.key,
    required this.chatId,
    required this.api,
    this.token,
  });

  @override
  State<SharedMediaSection> createState() => _SharedMediaSectionState();
}

class _SharedMediaSectionState extends State<SharedMediaSection>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = true;
  String? _error;
  List<MessageModel> _mediaList = [];
  List<MessageModel> _fileList = [];
  List<MessageModel> _voiceList = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSharedMedia();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSharedMedia() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/chats/${widget.chatId}/shared-media');
      if (!mounted) return;
      setState(() {
        _mediaList = (res['media'] as List? ?? [])
            .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _fileList = (res['files'] as List? ?? [])
            .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _voiceList = (res['voice'] as List? ?? [])
            .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _mediaUrl(String? mediaId) => resolveMediaUrl(mediaId);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).primaryColor,
          unselectedLabelColor: Colors.grey,
          tabs: [
            Tab(text: AppLocale.pick('عکس/ویدیو (${_mediaList.length})', 'Photos/Videos (${_mediaList.length})')),
            Tab(text: AppLocale.pick('فایل‌ها (${_fileList.length})', 'Files (${_fileList.length})')),
            Tab(text: AppLocale.pick('صوتی (${_voiceList.length})', 'Audio (${_voiceList.length})')),
          ],
        ),
        SizedBox(
          height: 280,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildMediaGrid(),
                        _buildFileList(),
                        _buildVoiceList(),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _buildMediaGrid() {
    if (_mediaList.isEmpty) {
      return Center(child: Text(AppLocale.pick('عکس یا ویدیویی وجود ندارد', 'No photos or videos yet'), style: const TextStyle(color: Colors.grey)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _mediaList.length,
      itemBuilder: (context, index) {
        final item = _mediaList[index];
        final url = _mediaUrl(item.mediaId);
        final isVideo = item.messageType == 'video';
        return GestureDetector(
          onTap: () {
            if (item.messageType == 'image' && !item.mediaExpired) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PhotoViewerScreen(
                    url: url,
                    token: widget.token,
                    caption: item.content,
                  ),
                ),
              );
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: item.mediaExpired
                    ? Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.image_not_supported_outlined, color: Colors.grey),
                            const SizedBox(height: 4),
                            Text(
                              MediaLabels.of(context).mediaExpired,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                          ],
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: url,
                        httpHeaders: widget.token != null ? {'Authorization': 'Bearer ${widget.token}'} : null,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: Colors.grey[300]),
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.broken_image, color: Colors.grey),
                        ),
                      ),
              ),
              if (isVideo && !item.mediaExpired)
                const Center(
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    radius: 18,
                    child: Icon(Icons.play_arrow, color: Colors.white, size: 22),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileList() {
    if (_fileList.isEmpty) {
      return Center(child: Text(AppLocale.pick('فایلی وجود ندارد', 'No files yet'), style: const TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _fileList.length,
      itemBuilder: (context, index) {
        final item = _fileList[index];
        final url = _mediaUrl(item.mediaId);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: FileMessageBubble(
            message: item,
            mediaUrl: url,
            token: widget.token,
            isMine: false,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
        );
      },
    );
  }

  Widget _buildVoiceList() {
    if (_voiceList.isEmpty) {
      return Center(child: Text(AppLocale.pick('پیام صوتی وجود ندارد', 'No audio messages yet'), style: const TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _voiceList.length,
      itemBuilder: (context, index) {
        final item = _voiceList[index];
        final url = _mediaUrl(item.mediaId);
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: item.mediaExpired
                ? Row(
                    children: [
                      const Icon(Icons.audiotrack_rounded, color: Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(MediaLabels.of(context).mediaExpired),
                            Text(
                              MediaLabels.of(context).mediaExpiredNotice,
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : VoiceMessagePlayer(
                    url: url,
                    token: widget.token,
                    foreground: Theme.of(context).colorScheme.onSurface,
                  ),
          ),
        );
      },
    );
  }
}
