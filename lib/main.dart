import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const KumoApp());

class KumoApp extends StatelessWidget {
  const KumoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Kumo Anime',
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xff0b0915),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffa78bfa),
        brightness: Brightness.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xff171326),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: const KumoHomePage(),
  );
}

class Anime {
  const Anime({
    required this.id,
    required this.title,
    this.poster,
    this.synopsis,
    this.episodes,
  });
  final int id;
  final String title;
  final String? poster;
  final String? synopsis;
  final int? episodes;
}

class StreamSource {
  const StreamSource({
    required this.name,
    required this.title,
    this.url,
    this.infoHash,
  });
  final String name, title;
  final String? url, infoHash;
}

class KumoApi {
  static const jikan = 'https://api.jikan.moe/v4';

  // Tanpa Real-Debrid, Torrentio hanya mengembalikan infoHash torrent,
  // sehingga sumber hanya bisa dibuka sebagai magnet di aplikasi eksternal.
  // Dengan API key Real-Debrid milik pengguna, Torrentio mengembalikan
  // tautan "resolve" yang bisa diputar langsung oleh video player.
  static String torrentioBase(String? rdApiKey) {
    var config =
        'providers=nyaasi,horriblesubs,anidex|sort=seeders|qualityfilter=720p,1080p';
    final key = rdApiKey?.trim() ?? '';
    if (key.isNotEmpty) config += '|realdebrid=$key';
    return 'https://torrentio.strem.fun/$config';
  }

  // Memeriksa API key ke Real-Debrid dan mengembalikan username pemiliknya.
  Future<String> checkRealDebrid(String rdApiKey) async {
    final response = await http.get(
      Uri.parse('https://api.real-debrid.com/rest/1.0/user'),
      headers: {'Authorization': 'Bearer ${rdApiKey.trim()}'},
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
        'API key Real-Debrid tidak valid atau sudah kedaluwarsa.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('Real-Debrid HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['username'] as String? ?? 'pengguna';
  }

  Future<Anime> searchAnime(String query) async {
    try {
      final response = await http.get(
        Uri.parse('$jikan/anime?q=${Uri.encodeQueryComponent(query)}&limit=1'),
      );
      if (response.statusCode != 200) {
        throw Exception('Jikan HTTP ${response.statusCode}');
      }
      final items = (jsonDecode(response.body)['data'] as List);
      if (items.isEmpty) throw Exception('Anime tidak ditemukan.');
      final item = items.first as Map<String, dynamic>;
      return Anime(
        id: item['mal_id'] as int,
        title: item['title'] as String? ?? query,
        poster:
            (item['images']?['jpg']?['large_image_url'] ??
                    item['images']?['jpg']?['image_url'])
                as String?,
        synopsis: item['synopsis'] as String?,
        episodes: item['episodes'] as int?,
      );
    } catch (e) {
      throw Exception('Gagal memuat metadata: $e');
    }
  }

  // Jikan mengembalikan ID MyAnimeList, sedangkan Torrentio untuk anime
  // memakai ID Kitsu (format stream "kitsu:{id}:{episode}"). Kedua ID itu
  // berbeda, jadi ID MAL harus dipetakan dulu lewat API mappings Kitsu.
  Future<String?> findKitsuId(int malId) async {
    final uri = Uri.https('kitsu.io', '/api/edge/mappings', {
      'filter[externalSite]': 'myanimelist/anime',
      'filter[externalId]': '$malId',
    });
    const headers = {'Accept': 'application/vnd.api+json'};
    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) return null;
    final data = (jsonDecode(response.body)['data'] as List? ?? const []);
    if (data.isEmpty) return null;
    final mapping = data.first as Map<String, dynamic>;
    // Sebagian respons menyertakan item-nya langsung.
    final embedded =
        mapping['relationships']?['item']?['data'] as Map<String, dynamic>?;
    if (embedded?['id'] != null) return embedded!['id'] as String;
    // Bentuk baku JSON:API Kitsu: item diambil lewat endpoint mapping-nya.
    final mappingId = mapping['id'] as String?;
    if (mappingId == null) return null;
    final itemResponse = await http.get(
      Uri.parse('https://kitsu.io/api/edge/mappings/$mappingId/item'),
      headers: headers,
    );
    if (itemResponse.statusCode != 200) return null;
    final item = jsonDecode(itemResponse.body)['data'] as Map<String, dynamic>?;
    return item?['id'] as String?;
  }

  Future<List<StreamSource>> getStreams(
    int malId,
    int episode, {
    String? rdApiKey,
  }) async {
    try {
      final kitsuId = await findKitsuId(malId);
      if (kitsuId == null) {
        throw Exception(
          'Anime ini belum terpetakan di Kitsu, jadi sumber streamingnya tidak bisa dicari.',
        );
      }
      final response = await http.get(
        Uri.parse(
          '${torrentioBase(rdApiKey)}/stream/anime/kitsu:$kitsuId:$episode.json',
        ),
      );
      if (response.statusCode != 200) {
        throw Exception('Torrentio HTTP ${response.statusCode}');
      }
      final list = (jsonDecode(response.body)['streams'] as List? ?? const []);
      return list.map((item) {
        final data = item as Map<String, dynamic>;
        return StreamSource(
          name: data['name'] as String? ?? 'Unknown',
          title: data['title'] as String? ?? 'Sumber streaming',
          url: data['url'] as String?,
          infoHash: data['infoHash'] as String?,
        );
      }).toList();
    } catch (e) {
      throw Exception('Gagal memuat sumber: $e');
    }
  }
}

class KumoHomePage extends StatefulWidget {
  const KumoHomePage({super.key});
  @override
  State<KumoHomePage> createState() => _KumoHomePageState();
}

class _KumoHomePageState extends State<KumoHomePage> {
  final api = KumoApi();
  final searchController = TextEditingController();
  final rdController = TextEditingController();
  Anime? anime;
  List<StreamSource> streams = [];
  List<Anime> library = [];
  List<String> recentSearches = [];
  int episode = 1, tab = 0;
  bool loading = false, saved = false;
  String? error;
  String rdKey = '';
  bool rdBusy = false;
  String? rdInfo;

  @override
  void initState() {
    super.initState();
    searchController.text = 'One Piece';
    _loadRdKey();
    _search('One Piece');
  }

  Future<void> _loadRdKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('rd_api_key') ?? '';
    if (!mounted) return;
    setState(() {
      rdKey = key;
      rdController.text = key;
      rdInfo = key.isEmpty
          ? null
          : 'Real-Debrid aktif di perangkat ini. Sumber RD bisa diputar langsung.';
    });
  }

  Future<void> _saveRdKey() async {
    final key = rdController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    if (key.isEmpty) {
      await prefs.remove('rd_api_key');
    } else {
      await prefs.setString('rd_api_key', key);
    }
    if (!mounted) return;
    setState(() {
      rdKey = key;
      streams = [];
      rdInfo = key.isEmpty
          ? 'Real-Debrid dimatikan. Sumber hanya bisa dibuka sebagai magnet.'
          : 'API key tersimpan. Cari sumber lagi agar tautan putar langsung muncul.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          key.isEmpty
              ? 'Real-Debrid dimatikan.'
              : 'API key Real-Debrid tersimpan di perangkat ini.',
        ),
      ),
    );
  }

  Future<void> _testRdKey() async {
    final key = rdController.text.trim();
    if (key.isEmpty) {
      setState(() => rdInfo = 'Isi dulu API key-nya, lalu ketuk Tes koneksi.');
      return;
    }
    setState(() {
      rdBusy = true;
      rdInfo = null;
    });
    try {
      final username = await api.checkRealDebrid(key);
      if (mounted) {
        setState(
          () =>
              rdInfo = 'Terhubung sebagai $username. Jangan lupa ketuk Simpan.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => rdInfo = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => rdBusy = false);
    }
  }

  Future<void> _search([String? value]) async {
    final query = (value ?? searchController.text).trim();
    if (query.isEmpty) return;
    setState(() {
      loading = true;
      error = null;
      streams = [];
    });
    try {
      final result = await api.searchAnime(query);
      if (!mounted) return;
      setState(() {
        anime = result;
        episode = 1;
        saved = library.any((a) => a.id == result.id);
        if (!recentSearches.contains(result.title)) {
          recentSearches.insert(0, result.title);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadStreams() async {
    final current = anime;
    if (current == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await api.getStreams(
        current.id,
        episode,
        rdApiKey: rdKey.isEmpty ? null : rdKey,
      );
      if (mounted) setState(() => streams = result);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _toggleSaved() {
    final current = anime;
    if (current == null) return;
    setState(() {
      saved = !saved;
      if (saved) {
        library.add(current);
      } else {
        library.removeWhere((a) => a.id == current.id);
      }
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    rdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: const Text(
        'kumo',
        style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -1),
      ),
      actions: [
        IconButton(
          onPressed: () => setState(() => tab = 2),
          icon: const Icon(Icons.bookmark_outline),
        ),
      ],
    ),
    body: IndexedStack(
      index: tab,
      children: [_home(), _searchPage(), _libraryPage()],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) => setState(() => tab = i),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Beranda',
        ),
        NavigationDestination(icon: Icon(Icons.search), label: 'Cari'),
        NavigationDestination(
          icon: Icon(Icons.bookmark_outline),
          selectedIcon: Icon(Icons.bookmark),
          label: 'Koleksi',
        ),
      ],
    ),
  );

  Widget _home() => RefreshIndicator(
    onRefresh: () => _search('One Piece'),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
      children: [
        const Text(
          'SELAMAT DATANG DI KUMO',
          style: TextStyle(
            color: Color(0xffa78bfa),
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Nonton anime\nfavoritmu.',
          style: TextStyle(
            fontSize: 32,
            height: 1.05,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 18),
        _searchField(),
        const SizedBox(height: 20),
        _rdCard(),
        const SizedBox(height: 20),
        if (loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: CircularProgressIndicator(),
            ),
          ),
        if (error != null) _errorCard(),
        if (anime != null) _animeCard(),
        if (streams.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionTitle('Sumber streaming'),
          ...streams.map((s) => _streamTile(s)),
        ],
        if (!loading && anime == null && error == null)
          _empty('Cari judul anime untuk memulai.'),
      ],
    ),
  );

  Widget _searchPage() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const Text(
        'Cari anime',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 18),
      _searchField(),
      const SizedBox(height: 24),
      if (recentSearches.isNotEmpty) ...[
        _sectionTitle('Pencarian terakhir'),
        ...recentSearches
            .take(6)
            .map(
              (x) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text(x),
                onTap: () {
                  searchController.text = x;
                  setState(() => tab = 0);
                  _search(x);
                },
              ),
            ),
      ] else
        _empty('Belum ada pencarian.'),
    ],
  );
  Widget _libraryPage() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const Text(
        'Koleksi saya',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      Text(
        '${library.length} anime tersimpan',
        style: const TextStyle(color: Color(0xffaaa4c9)),
      ),
      const SizedBox(height: 18),
      if (library.isEmpty) _empty('Simpan anime untuk menontonnya nanti.'),
      ...library.map(
        (item) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _poster(item.poster, 52, 72),
          title: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${item.episodes ?? '?'} episode'),
          onTap: () {
            setState(() {
              anime = item;
              saved = true;
              tab = 0;
            });
          },
        ),
      ),
    ],
  );

  Widget _rdCard() => Card(
    color: const Color(0xff171326),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xffff6eaa)),
              const SizedBox(width: 8),
              const Text(
                'Real-Debrid',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: rdKey.isEmpty
                      ? const Color(0xff2a2444)
                      : const Color(0xff14532d),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  rdKey.isEmpty ? 'Nonaktif' : 'Aktif',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Aktifkan agar sumber dari Torrentio bisa diputar langsung di aplikasi. Tanpa ini, sumber hanya bisa dibuka sebagai magnet di aplikasi torrent eksternal. API key bisa diambil di real-debrid.com/apitoken dan hanya tersimpan di perangkat ini.',
            style: TextStyle(height: 1.4, color: Color(0xffc3bedb)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: rdController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: 'Tempel API key Real-Debrid',
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          if (rdInfo != null) ...[
            const SizedBox(height: 10),
            Text(
              rdInfo!,
              style: const TextStyle(height: 1.4, color: Color(0xffa78bfa)),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: rdBusy ? null : _testRdKey,
                  child: Text(rdBusy ? 'Memeriksa...' : 'Tes koneksi'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saveRdKey,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffff5c8a),
                  ),
                  child: const Text('Simpan'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _searchField() => TextField(
    controller: searchController,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      hintText: 'Cari judul anime...',
      prefixIcon: const Icon(Icons.search),
      suffixIcon: IconButton(
        onPressed: _search,
        icon: const Icon(Icons.arrow_forward),
      ),
    ),
  );
  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
    ),
  );
  Widget _errorCard() => Card(
    color: const Color(0xff291827),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Color(0xffff91b0)),
          const SizedBox(width: 12),
          Expanded(child: Text(error!)),
          IconButton(
            onPressed: () => _search(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xffaaa4c9)),
      ),
    ),
  );
  Widget _poster(String? url, double w, double h) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: url == null
        ? SizedBox(
            width: w,
            height: h,
            child: const ColoredBox(
              color: Color(0xff211b35),
              child: Icon(Icons.image_outlined),
            ),
          )
        : Image.network(
            url,
            width: w,
            height: h,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => SizedBox(
              width: w,
              height: h,
              child: const Icon(Icons.broken_image),
            ),
          ),
  );
  Widget _animeCard() {
    final current = anime!;
    return Card(
      color: const Color(0xff171326),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _poster(current.poster, 112, 166),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${current.episodes ?? '?'} episode',
                        style: const TextStyle(color: Color(0xffaaa4c9)),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        current.synopsis ?? 'Sinopsis belum tersedia.',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          height: 1.4,
                          color: Color(0xffc3bedb),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _toggleSaved,
                  icon: Icon(
                    saved ? Icons.bookmark : Icons.bookmark_outline,
                    color: const Color(0xffff6eaa),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(current.id),
                    initialValue: episode,
                    decoration: const InputDecoration(labelText: 'Episode'),
                    items: [
                      for (var i = 1; i <= (current.episodes ?? 24); i++)
                        DropdownMenuItem(value: i, child: Text('Episode $i')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => episode = v);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _loadStreams,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffff5c8a),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 17,
                    ),
                  ),
                  child: const Text('Cari sumber'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _streamTile(StreamSource source) => Card(
    color: const Color(0xff171326),
    child: ListTile(
      leading: const Icon(
        Icons.play_circle_fill,
        color: Color(0xffff6eaa),
        size: 30,
      ),
      title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        source.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: FilledButton(
        onPressed: () => _openStream(source),
        child: const Text('Putar'),
      ),
    ),
  );
  Future<void> _openStream(StreamSource source) async {
    try {
      if (source.url == null) {
        final hash = source.infoHash;
        if (hash == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Sumber ini tidak punya tautan putar maupun infoHash.',
                ),
              ),
            );
          }
          return;
        }
        final magnet = Uri.parse(
          'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeQueryComponent(source.title)}',
        );
        final opened = await launchUrl(
          magnet,
          mode: LaunchMode.externalApplication,
        );
        if (!opened && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Sumber ini hanya infoHash dan membutuhkan aplikasi torrent eksternal.',
              ),
            ),
          );
        }
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPage(url: source.url!, title: source.name),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tidak dapat membuka video: $e')),
        );
      }
    }
  }
}

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.url, required this.title});
  final String url, title;
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final VideoPlayerController controller;
  @override
  void initState() {
    super.initState();
    controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          controller.play();
        }
      });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Center(
      child: controller.value.isInitialized
          ? AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            )
          : const CircularProgressIndicator(),
    ),
  );
}

// Torrent publik umumnya Eng Sub atau Raw. Subtitle Indonesia membutuhkan VTT/SRT melalui player/server yang mendukung subtitle track. Operator seluler dapat memblokir tracker publik; patuhi hukum setempat dan kebijakan ISP.
