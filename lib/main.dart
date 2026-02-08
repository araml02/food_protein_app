import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
            return const MainScreen(); // Ingelogd? Ga naar het hoofdscherm met tabs
          } else {
            return const LoginPage();
          }
        },
      ),
    );
  }
}

// --- HOOFDSCHERM MET TABS ---
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  
  // De twee hoofdpagina's
  final List<Widget> _pages = [
    const SearchPage(),
    const CommunityPage(),
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
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Producten'),
          NavigationDestination(icon: Icon(Icons.group), label: 'Community'),
        ],
      ),
    );
  }
}

// --- TAB 1: PRODUCTEN ZOEKEN (Jouw bestaande pagina) ---
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Toegevoegd aan favorieten!")));
    } catch (e) {
      await _supabase.from('favorites').delete().match({'user_id': user.id, 'product_code': productCode});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Verwijderd uit favorieten")));
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

      if (_showOnlyFavorites && user != null) {
        query = _supabase.from('favorites').select('products (*, prices(*))').eq('user_id', user.id);
      } else {
        query = _supabase.from('products').select('*, prices(*)');
      }

      String searchText = _searchController.text.trim();
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

      if (!_showOnlyFavorites) {
        if (_sortBy == 'protein') query = query.order('p', ascending: false);
        else if (_sortBy == 'name') query = query.order('name', ascending: true);
        else query = query.order('p', ascending: false);
      }

      final res = await query.limit(50);
      
      setState(() {
        if (_showOnlyFavorites) {
          _results = (res as List).map((e) => e['products']).where((e) => e != null).toList();
        } else {
          _results = res;
        }
        
        if (_sortBy == 'efficiency' || _showOnlyFavorites) {
          _results.sort((a, b) {
             double ratioA = (a['kcal'] ?? 0) > 0 ? (a['p'] ?? 0) / a['kcal'] : 0;
             double ratioB = (b['kcal'] ?? 0) > 0 ? (b['p'] ?? 0) / b['kcal'] : 0;
             return ratioB.compareTo(ratioA);
          });
        }
      });
    } catch (e) {
      debugPrint("Fout: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _submitPrice(String code, double price, String store) async {
    try {
      await _supabase.from('prices').insert({'product_code': code, 'price': price, 'store_name': store});
      _runSearch(); 
      if (mounted) Navigator.pop(context);
    } catch (e) { debugPrint("Fout: $e"); }
  }

  void _showPriceDialog(String code) {
    final priceCont = TextEditingController();
    String store = "Albert Heijn";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Prijs melden"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: priceCont, decoration: const InputDecoration(labelText: "Prijs (€)"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            DropdownButtonFormField<String>(
              value: store,
              items: ["Albert Heijn", "Jumbo", "Delhaize", "Aldi", "Lidl", "Colruyt"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => store = v!,
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuleer")),
          ElevatedButton(onPressed: () {
              final p = double.tryParse(priceCont.text.replaceFirst(',', '.'));
              if (p != null) _submitPrice(code, p, store);
            }, child: const Text("Opslaan")),
        ],
      ),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    List prices = prod['prices'] ?? [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(prod['name'], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(prod['brand'] ?? '', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _stat("${prod['p']}g", "Eiwit", Colors.green),
              _stat("${prod['kcal'].toInt()}", "Kcal", Colors.blue),
            ]),
            const Divider(),
            ...prices.map((pr) => ListTile(title: Text(pr['store_name']), trailing: Text("€${pr['price']}"))),
            ElevatedButton(onPressed: () => _showPriceDialog(prod['code']), child: const Text("Prijs toevoegen")),
          ],
        ),
      ),
    );
  }

  Widget _stat(String val, String lab, Color col) => Column(children: [
    Text(val, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.bold)),
    Text(lab)
  ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Eiwit Bijbel ☁️"),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: () => Supabase.instance.client.auth.signOut())
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "Zoek eiwit...",
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
              label: const Text("❤️ Favorieten"),
              selected: _showOnlyFavorites,
              onSelected: (v) => setState(() { _showOnlyFavorites = v; _runSearch(); }),
              selectedColor: Colors.red[100],
            ),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("Ratio"), selected: _sortBy == 'efficiency', onSelected: (s) { if(s) setState(() {_sortBy='efficiency'; _runSearch();}); }),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("Eiwit"), selected: _sortBy == 'protein', onSelected: (s) { if(s) setState(() {_sortBy='protein'; _runSearch();}); }),
          ]),
        ),
        Expanded(
          child: _loading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
            itemCount: _results.length,
            itemBuilder: (c, i) {
              final p = _results[i];
              double score = p['kcal'] > 0 ? (p['p'] / p['kcal']) * 100 : 0;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: ListTile(
                  title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${p['brand']} • ${p['p']}g eiwit"),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.favorite_border, color: Colors.red), onPressed: () => _toggleFavorite(p['code'])),
                    Text(score.toStringAsFixed(0), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  ]),
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

// --- TAB 2: COMMUNITY (NIEUW!) ---
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
      
      // Zoek profielen (behalve jezelf)
      var query = _supabase.from('profiles').select().neq('id', currentUserId);
      
      if (_userSearchController.text.isNotEmpty) {
        query = query.ilike('email', '%${_userSearchController.text}%');
      }

      final res = await query.limit(20);
      setState(() => _users = res);
    } catch (e) {
      debugPrint("Community fout: $e");
    } finally {
      setState(() => _loading = false);
    }
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
      appBar: AppBar(title: const Text("Vind gebruikers 👥")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _userSearchController,
              decoration: InputDecoration(
                labelText: "Zoek op email...",
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
                        leading: CircleAvatar(child: Text(user['email'][0].toUpperCase())),
                        title: Text(user['email']),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
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

// --- PAGINA: FAVORIETEN VAN IEMAND ANDERS BEKIJKEN ---
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
          .select('products (*, prices(*))') // We halen nu ook de prijzen op!
          .eq('user_id', widget.userId);

      setState(() {
        _products = (res as List).map((e) => e['products']).where((e) => e != null).toList();
      });
    } catch (e) {
      debugPrint("Fout bij laden favorieten: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  // --- DETAIL FUNCTIES (Gekopieerd en aangepast voor deze pagina) ---
  
  Future<void> _submitPrice(String code, double price, String store) async {
    try {
      await _supabase.from('prices').insert({
        'product_code': code,
        'price': price,
        'store_name': store,
      });
      _loadUserFavorites(); // Lijst verversen na toevoegen
      if (mounted) Navigator.pop(context);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Prijs opgeslagen!")));
    } catch (e) { debugPrint("Fout: $e"); }
  }

  void _showPriceDialog(String code) {
    final priceCont = TextEditingController();
    String store = "Albert Heijn";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Prijs melden"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: priceCont, decoration: const InputDecoration(labelText: "Prijs (€)"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: store,
              items: ["Albert Heijn", "Jumbo", "Delhaize", "Aldi", "Lidl", "Colruyt"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => store = v!,
              decoration: const InputDecoration(labelText: "Winkel"),
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuleer")),
          ElevatedButton(onPressed: () {
              final p = double.tryParse(priceCont.text.replaceFirst(',', '.'));
              if (p != null) _submitPrice(code, p, store);
            }, child: const Text("Opslaan")),
        ],
      ),
    );
  }

  void _showDetails(Map<String, dynamic> prod) {
    List prices = prod['prices'] ?? [];
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
            Text(prod['brand'] ?? 'Onbekend merk', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const Divider(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat("Eiwit", "${prod['p']}g", Colors.green),
                _stat("Kcal", "${prod['kcal'].toInt()}", Colors.blue),
                _stat("Ratio", (prod['p'] / prod['kcal'] * 100).toStringAsFixed(1), Colors.purple),
              ],
            ),
            const Divider(height: 30),
            const Text("Prijzen van gebruikers", style: TextStyle(fontWeight: FontWeight.bold)),
            if (prices.isEmpty) const Padding(padding: EdgeInsets.all(15), child: Text("Nog geen prijzen bekend...")),
            ...prices.map((pr) => ListTile(
              leading: const Icon(Icons.store, color: Colors.green),
              title: Text(pr['store_name']),
              trailing: Text("€${pr['price'].toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold)),
            )),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showPriceDialog(prod['code']),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text("Voeg prijs toe"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String lab, String val, Color col) => Column(children: [
        Text(val, style: TextStyle(color: col, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(lab, style: const TextStyle(fontWeight: FontWeight.w500))
      ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Lijst van ${widget.userEmail.split('@')[0]}")),
      body: _loading 
        ? const Center(child: CircularProgressIndicator())
        : _products.isEmpty 
          ? const Center(child: Text("Deze gebruiker heeft nog geen favorieten."))
          : ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index];
                double score = p['kcal'] > 0 ? (p['p'] / p['kcal']) * 100 : 0;
                
                // Bereken goedkoopste prijs (optioneel, voor de subtitel)
                List prices = p['prices'] ?? [];
                String? cheapestInfo;
                 if (prices.isNotEmpty && (p['p'] ?? 0) > 0) {
                  double min = -1;
                  for (var pr in prices) {
                    double pp = (pr['price'] ?? 0).toDouble() / p['p'];
                    if (min == -1 || pp < min) min = pp;
                  }
                  if (min > 0) cheapestInfo = "€${min.toStringAsFixed(3)} /g eiwit";
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
                        Text("${p['brand']} • ${p['p']}g eiwit"),
                        if (cheapestInfo != null) Text(cheapestInfo, style: const TextStyle(color: Colors.blueGrey, fontSize: 12))
                      ],
                    ),
                    trailing: Text("Score: ${score.toStringAsFixed(0)}", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    
                    // DEZE REGEL MISTE:
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

  Future<void> _handleAuth(bool isSignUp) async {
    setState(() => _loading = true);
    try {
      if (isSignUp) {
        await Supabase.instance.client.auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Account gemaakt!")));
      } else {
        await Supabase.instance.client.auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Fout: $e")));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Inloggen")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(controller: _emailController, decoration: const InputDecoration(labelText: "Email")),
            TextField(controller: _passwordController, decoration: const InputDecoration(labelText: "Wachtwoord"), obscureText: true),
            const SizedBox(height: 20),
            _loading ? const CircularProgressIndicator() : ElevatedButton(onPressed: () => _handleAuth(false), child: const Text("Log In")),
            TextButton(onPressed: () => _handleAuth(true), child: const Text("Maak account")),
          ],
        ),
      ),
    );
  }
}