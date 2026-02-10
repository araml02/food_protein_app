import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:google_generative_ai/google_generative_ai.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://rhydpzrgwzoqakygnixz.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJoeWRwenJnd3pvcWFreWduaXh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA1NDEwNDcsImV4cCI6MjA4NjExNzA0N30.lmekZXLMB5TaZHsEgD_iqanYGtLBQjnfoxbbSkisTp8',
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
  
  // The three main pages
  final List<Widget> _pages = [
    const SearchPage(),
    const DiscoverPage(),
    const CommunityPage(),
    const GainsBotPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Products'),
          NavigationDestination(icon: Icon(Icons.explore), label: 'Discover'),
          NavigationDestination(icon: Icon(Icons.group), label: 'Community'),
          NavigationDestination(icon: Icon(Icons.smart_toy), label: 'AI Coach'),
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
  List<dynamic> _results = [];
  bool _loading = false;
  bool _showOnlyFavorites = false; 
  String _sortBy = 'efficiency';
  final TextEditingController _searchController = TextEditingController();
  Set<String> _favoritedProductCodes = {};

  @override
  void initState() {
    super.initState();
    _runSearch(); 
  }

  Future<void> _toggleFavorite(String productCode) async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    try {
      await _supabase.from('favorites').insert({'user_id': user.id, 'product_code': productCode});
      setState(() => _favoritedProductCodes.add(productCode));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Added to favorites!")));
    } catch (e) {
      await _supabase.from('favorites').delete().match({'user_id': user.id, 'product_code': productCode});
      setState(() => _favoritedProductCodes.remove(productCode));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Removed from favorites")));
      if (_showOnlyFavorites) _runSearch();
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
              setState(() => _showOnlyFavorites = false);
              _runSearch();
            }
          },
        ),
      ),
    );
  }

void _runSearch() async {
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      dynamic query;
      String searchText = _searchController.text.trim();
      
      // TRUC: Als we op prijs filteren, gebruiken we '!inner'.
      // Dit dwingt Supabase om ALLEEN producten terug te geven die ook echt een prijs hebben.
      // Hierdoor verspillen we de limiet van 500 niet aan producten zonder prijs.
      String priceSelect = (_sortBy == 'price' && searchText.isEmpty) 
          ? 'prices!inner(*)'  // !inner = Alleen als er prijzen zijn
          : 'prices(*)';       // Normaal = Alles mag

      // 1. SELECT QUERY BOUWEN
      if (_showOnlyFavorites && user != null) {
        query = _supabase
            .from('favorites')
            .select('products (*, $priceSelect)') 
            .eq('user_id', user.id);
      } else {
        query = _supabase.from('products').select('*, $priceSelect');
      }

      // 2. ZOEK FILTERS
      if (searchText.isNotEmpty) {
        bool isBarcode = RegExp(r'^[0-9]+$').hasMatch(searchText);
        String codeCol = _showOnlyFavorites ? 'products.code' : 'code';
        String nameCol = _showOnlyFavorites ? 'products.name' : 'name';
        String brandCol = _showOnlyFavorites ? 'products.brand' : 'brand';

        if (isBarcode) {
          query = query.eq(codeCol, searchText);
        } else {
          List<String> words = searchText.split(' ').where((w) => w.isNotEmpty).toList();
          for (var word in words) {
            query = query.or('$nameCol.ilike.%$word%,$brandCol.ilike.%$word%');
          }
        }
      }

      // 3. SERVER-SIDE SORTERING (Voor niet-prijs filters)
      if (!_showOnlyFavorites && _sortBy != 'price') {
        if (_sortBy == 'protein') query = query.order('p', ascending: false);
        else if (_sortBy == 'name') query = query.order('name', ascending: true);
        else query = query.order('p', ascending: false);
      }

      // 4. DATA OPHALEN
      // Als we op prijs sorteren, halen we meer op (500), anders is 50 genoeg
      final limit = (_sortBy == 'price' && searchText.isEmpty) ? 500 : 50;
      final res = await query.limit(limit);
      
      // Favorieten ophalen voor de hartjes
      if (user != null) {
        final favRes = await _supabase.from('favorites').select('product_code').eq('user_id', user.id);
        _favoritedProductCodes = (favRes as List).map((e) => e['product_code'] as String).toSet();
      }
      
      setState(() {
        // 5. DATA UITPAKKEN
        if (_showOnlyFavorites) {
          _results = (res as List).map((e) => e['products']).where((e) => e != null).toList();
        } else {
          _results = res;
        }
        
        // 6. LOKALE SORTERING
        if (_sortBy == 'efficiency' || _showOnlyFavorites) {
          _results.sort((a, b) {
             double ratioA = (a['kcal'] ?? 0) > 0 ? (a['p'] ?? 0) / a['kcal'] : 0;
             double ratioB = (b['kcal'] ?? 0) > 0 ? (b['p'] ?? 0) / b['kcal'] : 0;
             return ratioB.compareTo(ratioA);
          });
        } else if (_sortBy == 'protein') {
          _results.sort((a, b) => (b['p'] ?? 0).compareTo(a['p'] ?? 0));
        } else if (_sortBy == 'price') {
          // Als we hier zijn, hebben we dankzij !inner alleen producten MET prijzen
          // We hoeven dus alleen nog maar te sorteren
          _results.sort((a, b) {
            double minA = _getMinPricePerGram(a);
            double minB = _getMinPricePerGram(b);
            return minA.compareTo(minB);
          });
        }
      });
    } catch (e) {
      debugPrint("Search error: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  // Hulpfunctie (deze moet je ook in je class hebben staan)
  double _getMinPricePerGram(Map product) {
    double min = double.infinity;
    List prices = product['prices'] ?? [];
    double protein = (product['p'] ?? 0).toDouble();
    if (protein <= 0) return double.infinity;

    for (var pr in prices) {
      double price = (pr['price'] ?? 0).toDouble();
      double pricePerGram = price / protein;
      if (pricePerGram < min) min = pricePerGram;
    }
    return min;
  }

  Future<void> _submitPrice(String code, double price, String store) async {
    try {
      await _supabase.from('prices').insert({'product_code': code, 'price': price, 'store_name': store});
      _runSearch(); 
      if (mounted) Navigator.pop(context);
    } catch (e) { debugPrint("Error: $e"); }
  }

  void _showPriceDialog(String code) {
    final priceCont = TextEditingController();
    String store = "Albert Heijn";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Add Price"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: priceCont, decoration: const InputDecoration(labelText: "Price (€)"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            DropdownButtonFormField<String>(
              value: store,
              items: ["Albert Heijn", "Jumbo", "Delhaize", "Aldi", "Lidl", "Colruyt"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => store = v!,
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(onPressed: () {
              final p = double.tryParse(priceCont.text.replaceFirst(',', '.'));
              if (p != null) _submitPrice(code, p, store);
            }, child: const Text("Save")),
        ],
      ),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    List prices = prod['prices'] ?? [];
    final num kcal = (prod['kcal'] ?? 0) as num;
    final num protein = (prod['p'] ?? 0) as num;
    final String ratio = kcal > 0 ? ((protein / kcal) * 100).toStringAsFixed(1) : '0.0';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              prod['name'],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            Text(prod['brand'] ?? 'Unknown brand', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat("${protein.toStringAsFixed(1)}g", "Protein", Colors.green),
                _stat("${kcal.toStringAsFixed(1)}", "Kcal", Colors.blue),
                _stat(ratio, "Ratio", Colors.purple),
              ],
            ),
            const Divider(height: 40),
            const Text("User Prices", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            if (prices.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text("No prices reported yet.")),
            ...prices.map((pr) {
              // Logic for Freshness
              final DateTime updatedAt = DateTime.parse(pr['created_at']);
              final int daysAgo = DateTime.now().difference(updatedAt).inDays;
              
              Color statusColor = daysAgo <= 7 ? Colors.green : (daysAgo <= 30 ? Colors.orange : Colors.red);
              String statusText = daysAgo == 0 ? "Verified today" : "Verified $daysAgo days ago";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: ListTile(
                  leading: Icon(Icons.history, color: statusColor.withOpacity(0.6)),
                  title: Text(pr['store_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("€${pr['price'].toStringAsFixed(2)}", 
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check_circle, color: Colors.blue),
                        onPressed: () async {
                          await _supabase
                              .from('prices')
                              .update({'created_at': DateTime.now().toIso8601String()})
                              .eq('id', pr['id']);
                          _runSearch();
                          if (mounted) Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Thanks for verifying!")));
                        },
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _showPriceDialog(prod['code']),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text("Add Price"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _stat(String val, String lab, Color col) => Column(children: [
    Text(val, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.bold)),
    Text(lab)
  ]);

  Widget _buildScoreCircle(double score) {
    Color scoreColor;
    if (score < 5) {
      scoreColor = Colors.red;
    } else if (score < 15) {
      scoreColor = Colors.orange;
    } else {
      scoreColor = Colors.green;
    }
    
    double progress = (score / 25).clamp(0, 1);
    
    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress,
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
            backgroundColor: Colors.grey[200],
          ),
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: scoreColor,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text("GainSaver"),
          actions: [
            IconButton(
              icon: const Icon(Icons.person_outline),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const ProfilePage())),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _runSearch,
            ),
          ],
        ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "Search protein...",
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _openScanner),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onChanged: (_) => _runSearch(),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 12),
          child: Row(children: [
            FilterChip(
              label: const Text("❤️ Favorites"),
              selected: _showOnlyFavorites,
              onSelected: (v) => setState(() { _showOnlyFavorites = v; _runSearch(); }),
              selectedColor: Colors.red[100],
            ),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("Ratio"), selected: _sortBy == 'efficiency', onSelected: (s) { if(s) setState(() {_sortBy='efficiency'; _runSearch();}); }),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("Protein"), selected: _sortBy == 'protein', onSelected: (s) { if(s) setState(() {_sortBy='protein'; _runSearch();}); }),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("Price/g"), selected: _sortBy == 'price', onSelected: (s) { if(s) setState(() {_sortBy='price'; _runSearch();}); }),
          ]),
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
              const Icon(Icons.search_off, size: 60, color: Colors.grey),
              const SizedBox(height: 20),
              Text(
                "No products found for\n'${_searchController.text}'",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () async {
                  // Check if the search term is a barcode (numbers only)
                  String? initialCode;
                  if (RegExp(r'^[0-9]+$').hasMatch(_searchController.text.trim())) {
                    initialCode = _searchController.text.trim();
                  }
                  
                  // Go to the add product screen
                  final bool? added = await Navigator.push(
                    context, 
                    MaterialPageRoute(builder: (context) => AddProductPage(initialCode: initialCode))
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
                ),
              )
            ],
          ),
        )
      // CASE 2: RESULTS FOUND -> SHOW LIST (Your old ListView code)
      : ListView.builder(
          itemCount: _results.length,
          itemBuilder: (c, i) {
            final p = _results[i];
            double score = p['kcal'] > 0 ? (p['p'] / p['kcal']) * 100 : 0;
            
            // Calculate freshest price info
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
                  // Skip invalid dates
                  continue;
                }
              }
              
              if (freshestPrice != null && freshestPrice > 0) {
                double pricePerGram = freshestPrice / p['p'];
                freshestPriceInfo = "€${pricePerGram.toStringAsFixed(3)} /g protein";
              }
            }

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: Colors.grey[200]!)),
              child: ListTile(
                title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("${p['brand']} • ${(p['p'] as num).toStringAsFixed(1)}g protein"),
                    if (freshestPriceInfo != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(freshestPriceInfo, style: const TextStyle(color: Colors.blueGrey, fontSize: 12, fontWeight: FontWeight.w600)),
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
      ]),
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
            productCounts[code] = {
              'count': 1,
              'product': product,
            };
          }
        }
      }

      // Convert to list and sort by count
      final List<Map<String, dynamic>> sorted = productCounts.values
          .map((item) => {
                'product': item['product'],
                'favorite_count': item['count'],
              })
          .toList();

      sorted.sort((a, b) => (b['favorite_count'] as int).compareTo(a['favorite_count'] as int));

      setState(() => _popularProducts = sorted);
    } catch (e) {
      debugPrint("Discover error: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showDetails(Map<String, dynamic> prod) {
    List prices = prod['prices'] ?? [];
    final num kcal = (prod['kcal'] ?? 0) as num;
    final num protein = (prod['p'] ?? 0) as num;
    final String ratio = kcal > 0 ? ((protein / kcal) * 100).toStringAsFixed(1) : '0.0';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              prod['name'],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            Text(prod['brand'] ?? 'Unknown brand', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat("${protein.toStringAsFixed(1)}g", "Protein", Colors.green),
                _stat("${kcal.toStringAsFixed(1)}", "Kcal", Colors.blue),
                _stat(ratio, "Ratio", Colors.purple),
              ],
            ),
            const Divider(height: 40),
            const Text("User Prices", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            if (prices.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text("No prices reported yet.")),
            ...prices.map((pr) {
              // Logic for Freshness
              final DateTime updatedAt = DateTime.parse(pr['created_at']);
              final int daysAgo = DateTime.now().difference(updatedAt).inDays;
              
              Color statusColor = daysAgo <= 7 ? Colors.green : (daysAgo <= 30 ? Colors.orange : Colors.red);
              String statusText = daysAgo == 0 ? "Verified today" : "Verified $daysAgo days ago";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: ListTile(
                  leading: Icon(Icons.history, color: statusColor.withOpacity(0.6)),
                  title: Text(pr['store_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("€${pr['price'].toStringAsFixed(2)}", 
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check_circle, color: Colors.blue),
                        onPressed: () async {
                          await _supabase
                              .from('prices')
                              .update({'created_at': DateTime.now().toIso8601String()})
                              .eq('id', pr['id']);
                          _loadPopularProducts();
                          if (mounted) Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Thanks for verifying!")));
                        },
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _stat(String val, String lab, Color col) => Column(children: [
        Text(val, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(lab)
      ]);

  Widget _buildScoreCircle(double score) {
    Color scoreColor;
    if (score < 5) {
      scoreColor = Colors.red;
    } else if (score < 15) {
      scoreColor = Colors.orange;
    } else {
      scoreColor = Colors.green;
    }

    double progress = (score / 25).clamp(0, 1);

    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress,
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
            backgroundColor: Colors.grey[200],
          ),
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: scoreColor,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Discover 🔥"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const ProfilePage())),
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
                    double score = product['kcal'] > 0 ? (product['p'] / product['kcal']) * 100 : 0;

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
                        freshestPriceInfo = "€${pricePerGram.toStringAsFixed(3)} /g protein";
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
                        title: Text(product['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("${product['brand']} • ${(product['p'] as num).toStringAsFixed(1)}g protein"),
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
                                "❤️ $favoriteCount ${favoriteCount == 1 ? 'person' : 'people'} love${favoriteCount == 1 ? 's' : ''} this",
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
      query = query.or('username.ilike.%${_userSearchController.text}%,email.ilike.%${_userSearchController.text}%');
    }

    final res = await query.limit(20);
    
    // Voor elke gebruiker de score ophalen via een RPC call
    List<Map<String, dynamic>> enrichedUsers = [];
    for (var user in res) {
      final score = await _supabase.rpc('get_contribution_score', params: {'target_user_id': user['id']});
      enrichedUsers.add({
        ...user,
        'score': score,
      });
    }

    setState(() => _users = enrichedUsers);
  } catch (e) { debugPrint("Community error: $e"); }
  finally { setState(() => _loading = false); }
}

  void _viewUserFavorites(Map<String, dynamic> userProfile) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => UserFavoritesPage(userId: userProfile['id'], userEmail: userProfile['email'])),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Find users 👥"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const ProfilePage())),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _searchUsers,
          ),
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
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
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.green[100],
                          child: Text((user['username'] ?? user['email'])[0].toUpperCase()),
                        ),
                        // SHOW USERNAME IF AVAILABLE, OTHERWISE EMAIL
                        title: Text(user['username'] ?? user['email'].split('@')[0]), 
                        subtitle: Text("Contribution Score: ${user['score']}"),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                        onTap: () => _viewUserFavorites(user),
                      ) ,
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

  const UserFavoritesPage({super.key, required this.userId, required this.userEmail});

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
        _products = (res as List).map((e) => e['products']).where((e) => e != null).toList();
      });
    } catch (e) {
      debugPrint("Error loading favorites: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  // --- DETAIL FUNCTIONS (Copied and adjusted for this page) ---
  
  Future<void> _submitPrice(String code, double price, String store) async {
    try {
      await _supabase.from('prices').insert({
        'product_code': code,
        'price': price,
        'store_name': store,
      });
      _loadUserFavorites(); // Refresh list after adding
      if (mounted) Navigator.pop(context);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Price saved!")));
    } catch (e) { debugPrint("Error: $e"); }
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Vote saved!"))
      );
    } catch (e) {
      debugPrint("Vote error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Could not save vote."))
      );
    }
  }

  void _showPriceDialog(String code) {
    final priceCont = TextEditingController();
    String store = "Albert Heijn";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Report price"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: priceCont, decoration: const InputDecoration(labelText: "Price (€)"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: store,
              items: ["Albert Heijn", "Jumbo", "Delhaize", "Aldi", "Lidl", "Colruyt"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => store = v!,
              decoration: const InputDecoration(labelText: "Store"),
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(onPressed: () {
              final p = double.tryParse(priceCont.text.replaceFirst(',', '.'));
              if (p != null) _submitPrice(code, p, store);
            }, child: const Text("Save")),
        ],
      ),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    List prices = prod['prices'] ?? [];
    final num kcal = (prod['kcal'] ?? 0) as num;
    final num protein = (prod['p'] ?? 0) as num;
    final String ratio = kcal > 0 ? ((protein / kcal) * 100).toStringAsFixed(1) : '0.0';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(prod['name'], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            Text(prod['brand'] ?? 'Unknown brand', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat("Protein", "${protein.toStringAsFixed(1)}g", Colors.green),
                _stat("Kcal", "${kcal.toStringAsFixed(1)}", Colors.blue),
                _stat("Ratio", ratio, Colors.purple),
              ],
            ),
            const Divider(height: 40),
            const Text("User Prices", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            if (prices.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text("No prices reported yet.")),
            ...prices.map((pr) {
              // Logic for Freshness
              final DateTime updatedAt = DateTime.parse(pr['created_at']);
              final int daysAgo = DateTime.now().difference(updatedAt).inDays;
              
              Color statusColor = daysAgo <= 7 ? Colors.green : (daysAgo <= 30 ? Colors.orange : Colors.red);
              String statusText = daysAgo == 0 ? "Verified today" : "Verified $daysAgo days ago";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: ListTile(
                  leading: Icon(Icons.history, color: statusColor.withOpacity(0.6)),
                  title: Text(pr['store_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("€${pr['price'].toStringAsFixed(2)}", 
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check_circle, color: Colors.blue),
                        onPressed: () async {
                          await _supabase
                              .from('prices')
                              .update({'created_at': DateTime.now().toIso8601String()})
                              .eq('id', pr['id']);
                          _loadUserFavorites();
                          if (mounted) Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Thanks for verifying!")));
                        },
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _showPriceDialog(prod['code']),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text("Add price"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _stat(String lab, String val, Color col) => Column(children: [
        Text(val, style: TextStyle(color: col, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(lab, style: const TextStyle(fontWeight: FontWeight.w500))
      ]);

  Widget _buildScoreCircle(double score) {
    Color scoreColor;
    if (score < 5) {
      scoreColor = Colors.red;
    } else if (score < 15) {
      scoreColor = Colors.orange;
    } else {
      scoreColor = Colors.green;
    }
    
    double progress = (score / 25).clamp(0, 1);
    
    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress,
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
            backgroundColor: Colors.grey[200],
          ),
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: scoreColor,
            ),
          ),
        ],
      ),
    );
  }

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
                double score = p['kcal'] > 0 ? (p['p'] / p['kcal']) * 100 : 0;
                
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
                    freshestInfo = "€${pricePerGram.toStringAsFixed(3)} /g protein";
                  }
                }

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: Colors.grey[200]!)),
                  child: ListTile(
                    title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("${p['brand']} • ${(p['p'] as num).toStringAsFixed(1)}g protein"),
                        if (freshestInfo != null) Text(freshestInfo, style: const TextStyle(color: Colors.blueGrey, fontSize: 12))
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
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
            const Text("GainSaver", textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            
            TextField(controller: _emailController, decoration: const InputDecoration(labelText: "Email", border: OutlineInputBorder(), prefixIcon: Icon(Icons.email))),
            const SizedBox(height: 15),
            TextField(controller: _passwordController, decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)), obscureText: true),
            
            const SizedBox(height: 25),
            
            _loading 
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(
                  onPressed: _signIn,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15), backgroundColor: Colors.green, foregroundColor: Colors.white),
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
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const SignUpPage()));
                  },
                  child: const Text("Create one here!"),
                )
              ],
            )
          ],
        ),
      ),
    );
  }
}


// --- NEW: PAGE TO ADD PRODUCTS ---
class AddProductPage extends StatefulWidget {
  final String? initialCode; // The barcode we already scanned

  const AddProductPage({super.key, this.initialCode});

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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Product successfully added!")));
        Navigator.pop(context, true); // True means: we added something
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e. Does this code already exist?"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("New Product 🆕")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text("Help the community and add a missing protein staple!", style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 20),
              
              // Barcode (Read-only if scanned, otherwise editable)
              TextFormField(
                controller: _codeController,
                decoration: const InputDecoration(labelText: "Barcode", border: OutlineInputBorder(), prefixIcon: Icon(Icons.qr_code)),
                validator: (v) => v == null || v.isEmpty ? "Barcode is required" : null,
              ),
              const SizedBox(height: 15),

              // Name and Brand
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: "Product name (e.g. Skyr Vanilla)", border: OutlineInputBorder(), prefixIcon: Icon(Icons.label)),
                validator: (v) => v == null || v.isEmpty ? "Name is required" : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(labelText: "Brand (e.g. Arla)", border: OutlineInputBorder(), prefixIcon: Icon(Icons.branding_watermark)),
              ),
              const SizedBox(height: 25),
              
              const Text("Nutritional values (per 100g)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 15),
              
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _pController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: "Protein (g)", border: OutlineInputBorder(), suffixText: "g"),
                      validator: (v) => v == null || v.isEmpty ? "Required" : null,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: TextFormField(
                      controller: _kcalController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: "Calories", border: OutlineInputBorder(), suffixText: "kcal"),
                      validator: (v) => v == null || v.isEmpty ? "Required" : null,
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
                  label: _loading ? const CircularProgressIndicator() : const Text("Save to Database", style: TextStyle(fontSize: 18)),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                ),
              )
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
    
    final data = await _supabase.from('profiles').select().eq('id', user.id).single();
    setState(() {
      _usernameController.text = data['username'] ?? "";
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      await _supabase.from('profiles').update({
        'username': _usernameController.text.trim(),
      }).eq('id', user!.id);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Profile updated!")));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: Username possibly already taken.")));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Profile 👤")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text("Choose a public username. Other users will see this name instead of your email."),
            const SizedBox(height: 20),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: "Username", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 20),
            _loading 
              ? const CircularProgressIndicator() 
              : ElevatedButton(onPressed: _saveProfile, child: const Text("Save")),
            const SizedBox(height: 40),
            const Divider(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => Supabase.instance.client.auth.signOut(),
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text("Log Out", style: TextStyle(color: Colors.red)),
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
        await _supabase.from('profiles').update({
          'username': _usernameController.text.trim(),
        }).eq('id', authRes.user!.id);

        if (mounted) {
          Navigator.pop(context); // Go back to login screen (or continue directly)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Account created! You are now logged in.")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Fout: $e"), backgroundColor: Colors.red),
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
              const Text("Choose a unique name and start your protein journey!", 
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 20),
              
              // Username
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: "Username", border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)),
                validator: (v) => v == null || v.length < 3 ? "Minimum 3 characters" : null,
              ),
              const SizedBox(height: 15),

              // Email
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: "Email", border: OutlineInputBorder(), prefixIcon: Icon(Icons.email)),
                validator: (v) => v == null || !v.contains('@') ? "Valid email address required" : null,
              ),
              const SizedBox(height: 15),

              // Password
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)),
                validator: (v) => v == null || v.length < 6 ? "Minimum 6 characters" : null,
              ),
              const SizedBox(height: 25),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _loading ? null : _signUp,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text("Register now"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- NIEUW: DE GAINSBOT PAGINA (AI ASSISTENT) ---
class GainsBotPage extends StatefulWidget {
  const GainsBotPage({super.key});

  @override
  State<GainsBotPage> createState() => _GainsBotPageState();
}

class _GainsBotPageState extends State<GainsBotPage> {
  // ⚠️ HAAL JE SLEUTEL BIJ: https://aistudio.google.com/
  static const _apiKey = 'AIzaSyCakEq1AvBbQrMpM2b_nDGwO6pHDJHYflg';
  
  late final GenerativeModel _model;
  late final ChatSession _chat;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, String>> _messages = []; // 'role': 'user' of 'model'
  bool _loading = false;

  @override
void initState() {
  super.initState();
  _model = GenerativeModel(
    // Probeer deze exacte naam, dit is de meest stabiele voor v1beta
    model: 'gemini-2.5-flash', 
    apiKey: _apiKey,
    systemInstruction: Content.text("You are GainsBot, the AI assistant for the 'GainSaver' app. You are an expert in protein, fitness, and nutrition. Keep your answers short, motivating, and focused on helping users find cheap protein."),
    
  );
  _chat = _model.startChat();
}

  Future<void> _sendMessage() async {
    final message = _textController.text.trim();
    if (message.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'text': message});
      _loading = true;
    });
    _textController.clear();
    _scrollToBottom();

    try {
  final response = await _chat.sendMessage(Content.text(message));
  final text = response.text ?? "I'm speechless (literally).";

  setState(() {
    _messages.add({'role': 'model', 'text': text});
    });
  } catch (e) {
    // DIT IS DE BELANGRIJKSTE REGEL:
    debugPrint("🚨 GOOGLE AI ERROR: $e"); 
    
    setState(() {
      _messages.add({
        'role': 'model', 
        'text': "An error occurred. Check the debug console for details."
      });
    });
  }
    finally {
      setState(() => _loading = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("GainsBot 🤖")),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty 
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(30.0),
                    child: Text(
                      "Ask me anything about protein!\n\nExample:\n'Is Skyr better than Quark?'\n'How much protein do I need?'",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(15),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    final isUser = msg['role'] == 'user';
                    return Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isUser ? Colors.green : Colors.grey[200],
                          borderRadius: BorderRadius.circular(15).copyWith(
                            bottomRight: isUser ? Radius.zero : null,
                            bottomLeft: !isUser ? Radius.zero : null,
                          ),
                        ),
                        child: Text(
                          msg['text']!,
                          style: TextStyle(color: isUser ? Colors.white : Colors.black87),
                        ),
                      ),
                    );
                  },
                ),
          ),
          if (_loading) const Padding(
            padding: EdgeInsets.all(8.0),
            child: CircularProgressIndicator(),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: "Ask GainsBot...",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(25)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _loading ? null : _sendMessage, 
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(backgroundColor: Colors.green),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}