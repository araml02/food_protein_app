import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'food_api_service.dart';
import 'helpers.dart';
import 'recipes_page.dart';

String formatPricePerGramInCents(double pricePerGramEuro) {
  final pricePerGramCents = pricePerGramEuro * 100;
  return '${pricePerGramCents.toStringAsFixed(1)} cent/g protein';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://rhydpzrgwzoqakygnixz.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJoeWRwenJnd3pvcWFreWduaXh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA1NDEwNDcsImV4cCI6MjA4NjExNzA0N30.lmekZXLMB5TaZHsEgD_iqanYGtLBQjnfoxbbSkisTp8',
  );

  runApp(const ProteinApp());
}

class ProteinApp extends StatelessWidget {
  const ProteinApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          final session = snapshot.data?.session;
          if (session != null) {
            return const MainScreen(); // Logged in? Go to main screen with tabs
          } else {
            return const LoginPage();
          }
        },
      ),
    );
  }
}

// --- MAIN SCREEN WITH TABS ---
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  // The main pages
  final List<Widget> _pages = [
    const SearchPage(),
    const DiscoverPage(),
    const FavoritesPage(),
    const RecipesPage(),
    const CommunityPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.fitness_center),
            label: 'Products',
          ),
          NavigationDestination(icon: Icon(Icons.explore), label: 'Discover'),
          NavigationDestination(icon: Icon(Icons.favorite), label: 'Favorites'),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu),
            label: 'Recipes',
          ),
          NavigationDestination(icon: Icon(Icons.group), label: 'Community'),
        ],
      ),
    );
  }
}

// --- TAB 1: SEARCH FOR PRODUCTS (Your existing page) ---
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _supabase = Supabase.instance.client;
  final _foodApiService = FoodApiService();
  Timer? _searchDebounce;
  int _searchRequestId = 0;
  List<Map<String, dynamic>> _fetchedData = [];
  List<dynamic> _results = [];
  bool _loading = false;
  String? _sortBy;
  final TextEditingController _searchController = TextEditingController();
  Set<String> _favoritedProductCodes = {};
  double? _maxPricePerGram; // null = no filter

  @override
  void initState() {
    super.initState();
    _runSearch(force: true);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _foodApiService.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _runSearch(),
    );
  }

  Future<void> _toggleFavorite(String productCode) async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final isCurrentlyFavorited = _favoritedProductCodes.contains(productCode);

    try {
      if (isCurrentlyFavorited) {
        // Remove from favorites
        await _supabase.from('favorites').delete().match({
          'user_id': user.id,
          'product_code': productCode,
        });
        setState(() => _favoritedProductCodes.remove(productCode));
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Removed from favorites")),
          );
      } else {
        // Add to favorites
        await _supabase.from('favorites').insert({
          'user_id': user.id,
          'product_code': productCode,
        });
        setState(() => _favoritedProductCodes.add(productCode));
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("Added to favorites!")));
      }

      _runSearch();
    } catch (e) {
      debugPrint("🚨 FAVORITE TOGGLE ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _openScanner() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: MobileScanner(
          onDetect: (capture) {
            final List<Barcode> barcodes = capture.barcodes;
            if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
              Navigator.pop(ctx);
              _searchController.text = barcodes.first.rawValue!;
              _runSearch();
            }
          },
        ),
      ),
    );
  }

  void _runSearch({bool force = false}) async {
    final int requestId = ++_searchRequestId;
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      final String searchText = _searchController.text.trim();
      final bool isBarcodeSearch = RegExp(r'^[0-9]+$').hasMatch(searchText);

      if (!force && !isBarcodeSearch && searchText.length < 2) {
        if (!mounted || requestId != _searchRequestId) return;
        setState(() {
          _fetchedData = [];
          _results = [];
        });
        return;
      }

      Set<String> favoriteCodes = {..._favoritedProductCodes};
      if (user != null && (force || _favoritedProductCodes.isEmpty)) {
        final favoritesRes = await _supabase
            .from('favorites')
            .select('product_code')
            .eq('user_id', user.id);

        favoriteCodes = (favoritesRes as List)
            .map((row) => (row['product_code'] ?? '').toString())
            .where((code) => code.isNotEmpty)
            .toSet();
      }

      List<Map<String, dynamic>> apiResults = [];
      if (searchText.isNotEmpty) {
        if (isBarcodeSearch) {
          final product = await _foodApiService.fetchProductFromOFF(searchText);
          if (product != null) {
            apiResults = [
              {
                ...product,
                // Ensure scanned/typed barcode is available for favorites/details.
                'code': (product['code'] ?? '').toString().isNotEmpty
                    ? product['code']
                    : searchText,
              },
            ];
          } else {
            // Fallback for barcodes not found by exact endpoint.
            apiResults = await _foodApiService.searchExternalProducts(
              searchText,
            );
          }
        } else {
          apiResults = await _foodApiService.searchExternalProducts(searchText);
        }
      }

      List<Map<String, dynamic>> fetchedData = apiResults
          .map(
            (product) => {
              ...product,
              'prices': <Map<String, dynamic>>[],
              'isFavorite': favoriteCodes.contains(
                (product['code'] ?? '').toString(),
              ),
              'source': 'api',
            },
          )
          .toList();

      if (!mounted || requestId != _searchRequestId) return;

      setState(() {
        _favoritedProductCodes = favoriteCodes;
        _fetchedData = fetchedData;
        _results = _buildVisibleResults(
          source: _fetchedData,
          searchText: searchText,
          isBarcodeSearch: isBarcodeSearch,
        );
      });
    } catch (e) {
      debugPrint("🚨 SEARCH CRITICAL ERROR: $e");
    } finally {
      if (mounted && requestId == _searchRequestId) {
        setState(() => _loading = false);
      }
    }
  }

  List<Map<String, dynamic>> _buildVisibleResults({
    required List<Map<String, dynamic>> source,
    required String searchText,
    required bool isBarcodeSearch,
  }) {
    List<Map<String, dynamic>> visible = List<Map<String, dynamic>>.from(
      source,
    );

    if (searchText.isNotEmpty && !isBarcodeSearch) {
      final List<String> searchWords = searchText
          .toLowerCase()
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList();

      visible = visible.where((p) {
        final String combinedText = '${p['name'] ?? ''} ${p['brand'] ?? ''}'
            .toLowerCase();
        return searchWords.every((word) => combinedText.contains(word));
      }).toList();
    }

    if (_maxPricePerGram != null) {
      visible = visible.where((p) {
        final double pricePerGram = _getMinPricePerGram(p);
        return pricePerGram > 0 && pricePerGram <= _maxPricePerGram!;
      }).toList();
    }

    if (_sortBy == 'efficiency') {
      visible.sort((a, b) {
        final double ratioA = (a['kcal'] ?? 0) > 0
            ? (a['p'] ?? 0) / a['kcal']
            : 0;
        final double ratioB = (b['kcal'] ?? 0) > 0
            ? (b['p'] ?? 0) / b['kcal']
            : 0;
        return ratioB.compareTo(ratioA);
      });
    } else if (_sortBy == 'price') {
      visible.sort(
        (a, b) => _getMinPricePerGram(a).compareTo(_getMinPricePerGram(b)),
      );
    } else if (_sortBy == 'name') {
      visible.sort(
        (a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo(
          (b['name'] ?? '').toString().toLowerCase(),
        ),
      );
    } else if (_sortBy == 'protein') {
      visible.sort(
        (a, b) => ((b['p'] as num?) ?? 0).compareTo((a['p'] as num?) ?? 0),
      );
    }

    return visible;
  }

  void _applyCurrentFiltersAndSort() {
    final String searchText = _searchController.text.trim();
    final bool isBarcodeSearch = RegExp(r'^[0-9]+$').hasMatch(searchText);
    setState(() {
      _results = _buildVisibleResults(
        source: _fetchedData,
        searchText: searchText,
        isBarcodeSearch: isBarcodeSearch,
      );
    });
  }

  double _getMinPricePerGram(Map product) => getMinPricePerGram(product);

  Future<void> _submitPrice(
    String code,
    double price,
    String store,
    double weight,
  ) async {
    await submitPrice(
      context,
      _supabase,
      code,
      price,
      store,
      weight,
      _runSearch,
    );
  }

  void _showPriceDialog(Map<String, dynamic> prod) {
    showPriceDialog(
      context,
      prod,
      _supabase,
      (code, price, store, weight) => _submitPrice(code, price, store, weight),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    showDetailsBottomSheet(context, prod, _supabase, _showPriceDialog);
  }

  void _showPricePerGramDialog() {
    final controller = TextEditingController(
      text: ((_maxPricePerGram ?? 0.10) * 100).toStringAsFixed(1),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Max Price per Gram'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Show only products with price per gram of protein below:',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                suffixText: 'cent/g',
                border: OutlineInputBorder(),
                hintText: '10',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final valueInCents = double.tryParse(controller.text);
              if (valueInCents != null && valueInCents > 0) {
                _maxPricePerGram = valueInCents / 100;
                _applyCurrentFiltersAndSort();
                Navigator.pop(ctx);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a valid price')),
                );
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _stat(String val, String lab, Color col) => buildStat(val, lab, col);

  Widget _buildScoreCircle(double score) => buildScoreCircle(score);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GainSaver"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const ProfilePage()),
            ),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _runSearch),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: "Search protein...",
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _openScanner,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              onChanged: (_) => _scheduleSearch(),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                FilterChip(
                  label: Text(
                    _maxPricePerGram == null
                        ? "Max cent/g"
                        : "≤${(_maxPricePerGram! * 100).toStringAsFixed(1)} cent/g",
                  ),
                  selected: _maxPricePerGram != null,
                  onSelected: (v) {
                    if (v) {
                      _showPricePerGramDialog();
                    } else {
                      _maxPricePerGram = null;
                      _applyCurrentFiltersAndSort();
                    }
                  },
                  selectedColor: Colors.green[100],
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text("Ratio"),
                  selected: _sortBy == 'efficiency',
                  onSelected: (s) {
                    _sortBy = s ? 'efficiency' : null;
                    _applyCurrentFiltersAndSort();
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text("Protein"),
                  selected: _sortBy == 'protein',
                  onSelected: (s) {
                    _sortBy = s ? 'protein' : null;
                    _applyCurrentFiltersAndSort();
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text("Price/g"),
                  selected: _sortBy == 'price',
                  onSelected: (s) {
                    _sortBy = s ? 'price' : null;
                    _applyCurrentFiltersAndSort();
                  },
                ),
              ],
            ),
          ),
          // Replace your current Expanded(...) with this block:
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                // CASE 1: NO RESULTS -> SHOW BUTTON
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.search_off,
                          size: 60,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          "No products found for\n'${_searchController.text}'",
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () async {
                            // Check if the search term is a barcode (numbers only)
                            String? initialCode;
                            if (RegExp(
                              r'^[0-9]+$',
                            ).hasMatch(_searchController.text.trim())) {
                              initialCode = _searchController.text.trim();
                            }

                            // Go to the add product screen
                            final bool? added = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    AddProductPage(initialCode: initialCode),
                              ),
                            );

                            // If we come back and something was added, refresh the search
                            if (added == true) {
                              _runSearch();
                            }
                          },
                          icon: const Icon(Icons.add_circle),
                          label: const Text("Add this product"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                // CASE 2: RESULTS FOUND -> SHOW LIST (Your old ListView code)
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (c, i) {
                      final p = _results[i];
                      double score = p['kcal'] > 0
                          ? (p['p'] / p['kcal']) * 400
                          : 0;

                      // Calculate freshest price info
                      List prices = p['prices'] ?? [];
                      String? freshestPriceInfo;
                      if (prices.isNotEmpty && (p['p'] ?? 0) > 0) {
                        DateTime? mostRecent;
                        double? freshestPrice;

                        for (var pr in prices) {
                          try {
                            DateTime priceDate = DateTime.parse(
                              pr['created_at'],
                            );
                            if (mostRecent == null ||
                                priceDate.isAfter(mostRecent)) {
                              mostRecent = priceDate;
                              freshestPrice = (pr['price'] ?? 0).toDouble();
                            }
                          } catch (e) {
                            // Skip invalid dates
                            continue;
                          }
                        }

                        if (freshestPrice != null && freshestPrice > 0) {
                          double pricePerGram = freshestPrice / p['p'];
                          freshestPriceInfo = formatPricePerGramInCents(
                            pricePerGram,
                          );
                        }
                      }

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                          side: BorderSide(color: Colors.grey[200]!),
                        ),
                        child: ListTile(
                          title: Text(
                            p['name'],
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      "${p['brand']} • ${(p['p'] as num).toStringAsFixed(1)}g protein",
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (p['source'] == 'supabase')
                                          ? Colors.green[100]
                                          : Colors.blue[100],
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      (p['source'] == 'supabase')
                                          ? 'Supabase'
                                          : 'OFF',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: (p['source'] == 'supabase')
                                            ? Colors.green[800]
                                            : Colors.blue[800],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (freshestPriceInfo != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    freshestPriceInfo,
                                    style: const TextStyle(
                                      color: Colors.blueGrey,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 36,
                                height: 36,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    _favoritedProductCodes.contains(p['code'])
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  onPressed: () => _toggleFavorite(p['code']),
                                ),
                              ),
                              const SizedBox(width: 3),
                              _buildScoreCircle(score),
                            ],
                          ),
                          onTap: () => _showDetails(p),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _supabase = Supabase.instance.client;
  List<dynamic> _products = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        setState(() => _products = []);
        return;
      }

      final res = await _supabase
          .from('favorites')
          .select('products (*, prices(*))')
          .eq('user_id', user.id);

      setState(() {
        _products = (res as List)
            .map((row) => row['products'])
            .where((product) => product != null)
            .toList();
      });
    } catch (e) {
      debugPrint('Favorites load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeFavorite(String code) async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    await _supabase.from('favorites').delete().match({
      'user_id': user.id,
      'product_code': code,
    });

    _loadFavorites();
  }

  void _showPriceDialog(Map<String, dynamic> product) {
    showPriceDialog(
      context,
      product,
      _supabase,
      (code, price, store, weight) => submitPrice(
        context,
        _supabase,
        code,
        price,
        store,
        weight,
        _loadFavorites,
      ),
    );
  }

  void _showDetails(Map<String, dynamic> product) {
    showDetailsBottomSheet(context, product, _supabase, _showPriceDialog);
  }

  Widget _buildScoreCircle(double score) => buildScoreCircle(score);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorites'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFavorites,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
          ? const Center(child: Text('No favorites yet.'))
          : ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index] as Map<String, dynamic>;
                final double score = (p['kcal'] ?? 0) > 0
                    ? (p['p'] / p['kcal']) * 400
                    : 0;

                List prices = p['prices'] ?? [];
                String? freshestPriceInfo;
                if (prices.isNotEmpty && (p['p'] ?? 0) > 0) {
                  DateTime? mostRecent;
                  double? freshestPrice;

                  for (var pr in prices) {
                    try {
                      DateTime priceDate = DateTime.parse(pr['created_at']);
                      if (mostRecent == null || priceDate.isAfter(mostRecent)) {
                        mostRecent = priceDate;
                        freshestPrice = (pr['price'] ?? 0).toDouble();
                      }
                    } catch (e) {
                      continue;
                    }
                  }

                  if (freshestPrice != null && freshestPrice > 0) {
                    final double pricePerGram = freshestPrice / p['p'];
                    freshestPriceInfo = formatPricePerGramInCents(pricePerGram);
                  }
                }

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    title: Text(
                      (p['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${p['brand'] ?? ''} • ${((p['p'] as num?) ?? 0).toStringAsFixed(1)}g protein',
                        ),
                        if (freshestPriceInfo != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              freshestPriceInfo,
                              style: const TextStyle(
                                color: Colors.blueGrey,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.favorite, color: Colors.red),
                          onPressed: () =>
                              _removeFavorite((p['code'] ?? '').toString()),
                        ),
                        _buildScoreCircle(score),
                      ],
                    ),
                    onTap: () => _showDetails(p),
                  ),
                );
              },
            ),
    );
  }
}

// --- TAB 2: DISCOVER (MOST FAVORITED) ---
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});
  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final _supabase = Supabase.instance.client;
  List<dynamic> _popularProducts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPopularProducts();
  }

  void _loadPopularProducts() async {
    setState(() => _loading = true);
    try {
      // Get all favorites with product data
      final favoritesData = await _supabase
          .from('favorites')
          .select('product_code, products (*, prices(*))');

      // Count favorites per product
      final Map<String, dynamic> productCounts = {};
      for (var fav in (favoritesData as List)) {
        final code = fav['product_code'];
        final product = fav['products'];
        if (product != null) {
          if (productCounts.containsKey(code)) {
            productCounts[code]['count']++;
          } else {
            productCounts[code] = {'count': 1, 'product': product};
          }
        }
      }

      // Convert to list and sort by count
      final List<Map<String, dynamic>> sorted = productCounts.values
          .map(
            (item) => {
              'product': item['product'],
              'favorite_count': item['count'],
            },
          )
          .toList();

      sorted.sort(
        (a, b) =>
            (b['favorite_count'] as int).compareTo(a['favorite_count'] as int),
      );

      setState(() => _popularProducts = sorted);
    } catch (e) {
      debugPrint("Discover error: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  // --- WRAPPER METHODS (gebruik helpers.dart functies) ---
  void _showDetails(Map<String, dynamic> prod) {
    showDetailsBottomSheet(
      context,
      prod,
      _supabase,
      (_) {}, // Dummy - DiscoverPage toont geen AddPrice knop
      showAddPriceButton: false,
    );
  }

  // --- WRAPPER METHODS (gebruik helpers.dart functies) ---
  double _getMinPricePerGram(Map product) => getMinPricePerGram(product);
  Widget _stat(String val, String lab, Color col) => buildStat(val, lab, col);
  Widget _buildScoreCircle(double score) => buildScoreCircle(score);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Discover"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const ProfilePage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPopularProducts,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _popularProducts.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.explore_off, size: 60, color: Colors.grey),
                  SizedBox(height: 20),
                  Text(
                    "No popular products yet.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _popularProducts.length,
              itemBuilder: (context, index) {
                final item = _popularProducts[index];
                final product = item['product'];
                final favoriteCount = item['favorite_count'];
                double score = product['kcal'] > 0
                    ? (product['p'] / product['kcal']) * 400
                    : 0;

                // Calculate freshest price info
                List prices = product['prices'] ?? [];
                String? freshestPriceInfo;
                if (prices.isNotEmpty && (product['p'] ?? 0) > 0) {
                  DateTime? mostRecent;
                  double? freshestPrice;

                  for (var pr in prices) {
                    try {
                      DateTime priceDate = DateTime.parse(pr['created_at']);
                      if (mostRecent == null || priceDate.isAfter(mostRecent)) {
                        mostRecent = priceDate;
                        freshestPrice = (pr['price'] ?? 0).toDouble();
                      }
                    } catch (e) {
                      // Skip invalid dates
                      continue;
                    }
                  }

                  if (freshestPrice != null && freshestPrice > 0) {
                    double pricePerGram = freshestPrice / product['p'];
                    freshestPriceInfo = formatPricePerGramInCents(pricePerGram);
                  }
                }

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                    side: BorderSide(color: Colors.orange[100]!, width: 2),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.orange[100],
                      child: Text(
                        "$favoriteCount",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                    title: Text(
                      product['name'],
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${product['brand']} • ${(product['p'] as num).toStringAsFixed(1)}g protein",
                        ),
                        if (freshestPriceInfo != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              freshestPriceInfo,
                              style: const TextStyle(
                                color: Colors.blueGrey,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            "$favoriteCount ${favoriteCount == 1 ? 'person' : 'people'} ${favoriteCount == 1 ? 'likes' : 'like'} this",
                            style: TextStyle(
                              color: Colors.red[400],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    trailing: _buildScoreCircle(score),
                    onTap: () => _showDetails(product),
                  ),
                );
              },
            ),
    );
  }
}

// --- TAB 3: COMMUNITY (NEW!) ---
class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  final _supabase = Supabase.instance.client;
  List<dynamic> _users = [];
  bool _loading = false;
  final _userSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchUsers();
  }

  void _searchUsers() async {
    setState(() => _loading = true);
    try {
      final currentUserId = _supabase.auth.currentUser!.id;
      // We also fetch 'username' now
      var query = _supabase.from('profiles').select().neq('id', currentUserId);

      if (_userSearchController.text.isNotEmpty) {
        // Search on username OR email
        query = query.or(
          'username.ilike.%${_userSearchController.text}%,email.ilike.%${_userSearchController.text}%',
        );
      }

      final res = await query.limit(20);

      final enrichedUsers = (res as List)
          .map((user) => {...(user as Map), 'score': 0})
          .toList();

      setState(() => _users = enrichedUsers);
    } catch (e) {
      debugPrint("Community error: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  void _viewUserFavorites(Map<String, dynamic> userProfile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserFavoritesPage(
          userId: userProfile['id'],
          userEmail: userProfile['email'],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Find users"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const ProfilePage()),
            ),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _searchUsers),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _userSearchController,
              decoration: InputDecoration(
                labelText: "Search by email...",
                prefixIcon: const Icon(Icons.person_search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              onChanged: (_) => _searchUsers(),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.green[100],
                            child: Text(
                              (user['username'] ?? user['email'])[0]
                                  .toUpperCase(),
                            ),
                          ),
                          // SHOW USERNAME IF AVAILABLE, OTHERWISE EMAIL
                          title: Text(
                            user['username'] ?? user['email'].split('@')[0],
                          ),
                          subtitle: Text(
                            "Contribution Score: ${user['score']}",
                          ),
                          trailing: const Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                          ),
                          onTap: () => _viewUserFavorites(user),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// --- PAGE: VIEW SOMEONE ELSE'S FAVORITES ---
class UserFavoritesPage extends StatefulWidget {
  final String userId;
  final String userEmail;

  const UserFavoritesPage({
    super.key,
    required this.userId,
    required this.userEmail,
  });

  @override
  State<UserFavoritesPage> createState() => _UserFavoritesPageState();
}

class _UserFavoritesPageState extends State<UserFavoritesPage> {
  final _supabase = Supabase.instance.client;
  List<dynamic> _products = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUserFavorites();
  }

  void _loadUserFavorites() async {
    try {
      final res = await _supabase
          .from('favorites')
          .select('products (*, prices(*))')
          .eq('user_id', widget.userId);

      setState(() {
        _products = (res as List)
            .map((e) => e['products'])
            .where((e) => e != null)
            .toList();
      });
    } catch (e) {
      debugPrint("Error loading favorites: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  // --- DETAIL FUNCTIONS (Copied and adjusted for this page) ---

  Future<void> _submitPrice(
    String code,
    double price,
    String store,
    double weight,
  ) async {
    await submitPrice(
      context,
      _supabase,
      code,
      price,
      store,
      weight,
      _loadUserFavorites,
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Price saved!")));
    }
  }

  Future<void> _votePrice(int priceId, int voteValue) async {
    try {
      await _supabase.from('price_votes').upsert({
        'price_id': priceId,
        'user_id': _supabase.auth.currentUser!.id,
        'vote': voteValue,
      });
      // Refresh to show new vote count
      _loadUserFavorites();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Vote saved!")));
    } catch (e) {
      debugPrint("Vote error: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Could not save vote.")));
    }
  }

  void _showPriceDialog(Map<String, dynamic> prod) {
    showPriceDialog(
      context,
      prod,
      _supabase,
      (code, price, store, weight) => _submitPrice(code, price, store, weight),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    showDetailsBottomSheet(context, prod, _supabase, _showPriceDialog);
  }

  // --- WRAPPER METHODS (gebruik helpers.dart functies) ---
  double _getMinPricePerGram(Map product) => getMinPricePerGram(product);
  Widget _stat(String val, String lab, Color col) => buildStat(val, lab, col);
  Widget _buildScoreCircle(double score) => buildScoreCircle(score);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("List of ${widget.userEmail.split('@')[0]}")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
          ? const Center(child: Text("This user has no favorites yet."))
          : ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index];
                double score = p['kcal'] > 0 ? (p['p'] / p['kcal']) * 400 : 0;

                // Calculate freshest price info
                List prices = p['prices'] ?? [];
                String? freshestInfo;
                if (prices.isNotEmpty && (p['p'] ?? 0) > 0) {
                  DateTime? mostRecent;
                  double? freshestPrice;

                  for (var pr in prices) {
                    try {
                      DateTime priceDate = DateTime.parse(pr['created_at']);
                      if (mostRecent == null || priceDate.isAfter(mostRecent)) {
                        mostRecent = priceDate;
                        freshestPrice = (pr['price'] ?? 0).toDouble();
                      }
                    } catch (e) {
                      // Skip invalid dates
                      continue;
                    }
                  }

                  if (freshestPrice != null && freshestPrice > 0) {
                    double pricePerGram = freshestPrice / p['p'];
                    freshestInfo = formatPricePerGramInCents(pricePerGram);
                  }
                }

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                    side: BorderSide(color: Colors.grey[200]!),
                  ),
                  child: ListTile(
                    title: Text(
                      p['name'],
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${p['brand']} • ${(p['p'] as num).toStringAsFixed(1)}g protein",
                        ),
                        if (freshestInfo != null)
                          Text(
                            freshestInfo,
                            style: const TextStyle(
                              color: Colors.blueGrey,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                    trailing: _buildScoreCircle(score),

                    // THIS LINE WAS MISSING:
                    onTap: () => _showDetails(p),
                  ),
                );
              },
            ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  Future<void> _signIn() async {
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      // The StreamBuilder in main.dart handles the rest
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.fitness_center, size: 80, color: Colors.green),
            const SizedBox(height: 20),
            const Text(
              "GainSaver",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),

            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: "Email",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: "Password",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock),
              ),
              obscureText: true,
            ),

            const SizedBox(height: 25),

            _loading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: _signIn,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text("Log In", style: TextStyle(fontSize: 16)),
                  ),

            const SizedBox(height: 20),

            // HERE IS THE ADJUSTMENT:
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Don't have an account?"),
                TextButton(
                  onPressed: () {
                    // Go to the new registration screen
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SignUpPage(),
                      ),
                    );
                  },
                  child: const Text("Create one here!"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- NEW: PAGE TO ADD PRODUCTS ---
class AddProductPage extends StatefulWidget {
  final String? initialCode; // The barcode we already scanned
  final Map<String, dynamic>? initialProductData;

  const AddProductPage({super.key, this.initialCode, this.initialProductData});

  @override
  State<AddProductPage> createState() => _AddProductPageState();
}

class _AddProductPageState extends State<AddProductPage> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _brandController = TextEditingController();
  final _pController = TextEditingController();
  final _kcalController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialCode != null) {
      _codeController.text = widget.initialCode!;
    }

    final productData = widget.initialProductData;
    if (productData != null) {
      _nameController.text = (productData['name'] ?? '').toString();
      _brandController.text = (productData['brand'] ?? '').toString();
      _pController.text = _numToText(productData['p']);
      _kcalController.text = _numToText(productData['kcal']);
    }
  }

  String _numToText(dynamic value) {
    if (value == null) return '';
    if (value is num) return value.toString();
    return value.toString();
  }

  Future<void> _saveProduct() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      final supabase = Supabase.instance.client;

      // Prepare data
      final productData = {
        'code': _codeController.text.trim(),
        'name': _nameController.text.trim(),
        'brand': _brandController.text.trim(),
        'p': double.parse(_pController.text.replaceAll(',', '.')),
        'kcal': double.parse(_kcalController.text.replaceAll(',', '.')),
        'c': 0, // Optional: add later
        'f': 0, // Optional: add later
      };

      // Save to Supabase
      await supabase.from('products').insert(productData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Product successfully added!")),
        );
        Navigator.pop(context, true); // True means: we added something
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error: $e. Does this code already exist?"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("New Product")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Help the community and add a missing protein staple!",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 20),

              // Barcode (Read-only if scanned, otherwise editable)
              TextFormField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: "Barcode",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.qr_code),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? "Barcode is required" : null,
              ),
              const SizedBox(height: 15),

              // Name and Brand
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: "Product name (e.g. Skyr Vanilla)",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? "Name is required" : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(
                  labelText: "Brand (e.g. Arla)",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.branding_watermark),
                ),
              ),
              const SizedBox(height: 25),

              const Text(
                "Nutritional values (per 100g)",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 15),

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _pController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: "Protein (g)",
                        border: OutlineInputBorder(),
                        suffixText: "g",
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? "Required" : null,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: TextFormField(
                      controller: _kcalController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: "Calories",
                        border: OutlineInputBorder(),
                        suffixText: "kcal",
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? "Required" : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _loading ? null : _saveProduct,
                  icon: _loading ? const SizedBox() : const Icon(Icons.save),
                  label: _loading
                      ? const CircularProgressIndicator()
                      : const Text(
                          "Save to Database",
                          style: TextStyle(fontSize: 18),
                        ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _supabase = Supabase.instance.client;
  final _usernameController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final data = await _supabase
        .from('profiles')
        .select()
        .eq('id', user.id)
        .single();
    setState(() {
      _usernameController.text = data['username'] ?? "";
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      await _supabase
          .from('profiles')
          .update({'username': _usernameController.text.trim()})
          .eq('id', user!.id);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Profile updated!")));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: Username possibly already taken.")),
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Profile")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              "Choose a public username. Other users will see this name instead of your email.",
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: "Username",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            _loading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _saveProfile,
                    child: const Text("Save"),
                  ),
            const SizedBox(height: 40),
            const Divider(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => Supabase.instance.client.auth.signOut(),
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text(
                  "Log Out",
                  style: TextStyle(color: Colors.red),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _supabase = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      // 1. Create the user in Supabase Auth
      final authRes = await _supabase.auth.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      // If registration succeeded, we now have a User ID
      if (authRes.user != null) {
        // 2. Update the profile with the username
        // (The trigger in the database already created the row, we now fill in the name)
        await _supabase
            .from('profiles')
            .update({'username': _usernameController.text.trim()})
            .eq('id', authRes.user!.id);

        if (mounted) {
          Navigator.pop(
            context,
          ); // Go back to login screen (or continue directly)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Account created! You are now logged in."),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Create account")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              const Text(
                "Choose a unique name and start your protein journey!",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 20),

              // Username
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: "Username",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (v) =>
                    v == null || v.length < 3 ? "Minimum 3 characters" : null,
              ),
              const SizedBox(height: 15),

              // Email
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: "Email",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                validator: (v) => v == null || !v.contains('@')
                    ? "Valid email address required"
                    : null,
              ),
              const SizedBox(height: 15),

              // Password
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Password",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                validator: (v) =>
                    v == null || v.length < 6 ? "Minimum 6 characters" : null,
              ),
              const SizedBox(height: 25),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _loading ? null : _signUp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Register now"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
