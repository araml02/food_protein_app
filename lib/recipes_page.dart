import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final List<Map<String, dynamic>> _recipes = [];
  final Set<String> _likedRecipeIds = <String>{};

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecipes();
  }

  String _formatCentPerProtein(dynamic value) {
    if (value == null) return 'No price data';
    final num? n = value as num?;
    if (n == null) return 'No price data';
    return '${n.toStringAsFixed(1)} cent/g protein';
  }

  Future<void> _loadRecipes() async {
    setState(() => _loading = true);
    try {
      final user = _supabase.auth.currentUser;
      final recipeRows = await _supabase
          .from('recipe_feed')
          .select()
          .order('created_at', ascending: false);

      final recipes = (recipeRows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final ids = recipes
          .map((r) => (r['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();

      Set<String> liked = <String>{};
      if (user != null && ids.isNotEmpty) {
        final likes = await _supabase
            .from('recipe_likes')
            .select('recipe_id')
            .eq('user_id', user.id)
            .inFilter('recipe_id', ids);
        liked = (likes as List)
            .map((e) => (e['recipe_id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toSet();
      }

      if (!mounted) return;
      setState(() {
        _recipes
          ..clear()
          ..addAll(recipes);
        _likedRecipeIds
          ..clear()
          ..addAll(liked);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load recipes: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleLike(Map<String, dynamic> recipe) async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to like recipes.')),
      );
      return;
    }

    final recipeId = (recipe['id'] ?? '').toString();
    if (recipeId.isEmpty) return;

    final liked = _likedRecipeIds.contains(recipeId);
    try {
      if (liked) {
        await _supabase.from('recipe_likes').delete().match({
          'recipe_id': recipeId,
          'user_id': user.id,
        });
      } else {
        await _supabase.from('recipe_likes').insert({
          'recipe_id': recipeId,
          'user_id': user.id,
        });
      }
      await _loadRecipes();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update like: $e')));
    }
  }

  Future<void> _togglePrivacy(Map<String, dynamic> recipe) async {
    final recipeId = (recipe['id'] ?? '').toString();
    if (recipeId.isEmpty) return;

    final bool current = recipe['is_public'] == true;
    try {
      await _supabase
          .from('recipes')
          .update({'is_public': !current})
          .eq('id', recipeId);
      await _loadRecipes();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update privacy: $e')));
    }
  }

  Future<void> _openCreateRecipeDialog() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final titleController = TextEditingController();
    final descController = TextEditingController();
    bool isPublic = false;
    final List<Map<String, dynamic>> selectedIngredients = [];

    Future<void> addIngredientFlow(StateSetter setModalState) async {
      final picked = await _showProductPicker();
      if (picked == null) return;

      final grams = await _askForGrams();
      if (grams == null) return;

      setModalState(() {
        selectedIngredients.add({
          'product_code': picked['code'],
          'product_name': picked['name'],
          'grams': grams,
        });
      });
    }

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Create Recipe',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Make public'),
                      value: isPublic,
                      onChanged: (v) => setModalState(() => isPublic = v),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: selectedIngredients.asMap().entries.map((
                        entry,
                      ) {
                        final idx = entry.key;
                        final item = entry.value;
                        return InputChip(
                          label: Text(
                            '${item['product_name']} (${item['grams']}g)',
                          ),
                          onDeleted: () {
                            setModalState(() {
                              selectedIngredients.removeAt(idx);
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () => addIngredientFlow(setModalState),
                      icon: const Icon(Icons.add),
                      label: const Text('Add ingredient'),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          final title = titleController.text.trim();
                          if (title.isEmpty || selectedIngredients.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Title and at least one ingredient are required.',
                                ),
                              ),
                            );
                            return;
                          }

                          try {
                            final recipeInsert = await _supabase
                                .from('recipes')
                                .insert({
                                  'owner_id': user.id,
                                  'title': title,
                                  'description': descController.text.trim(),
                                  'is_public': isPublic,
                                })
                                .select('id')
                                .single();

                            final recipeId = (recipeInsert['id'] ?? '')
                                .toString();
                            if (recipeId.isEmpty) {
                              throw Exception('Recipe id not returned.');
                            }

                            final items = selectedIngredients
                                .asMap()
                                .entries
                                .map(
                                  (entry) => {
                                    'recipe_id': recipeId,
                                    'product_code': entry.value['product_code'],
                                    'grams': entry.value['grams'],
                                    'position': entry.key,
                                  },
                                )
                                .toList();

                            await _supabase.from('recipe_items').insert(items);

                            if (context.mounted) Navigator.pop(context);
                            await _loadRecipes();
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Could not save recipe: $e'),
                              ),
                            );
                          }
                        },
                        child: const Text('Save recipe'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _showProductPicker() async {
    final searchController = TextEditingController();
    final List<Map<String, dynamic>> favoriteProducts = [];
    final List<Map<String, dynamic>> results = [];
    bool isLoading = false;

    void search(StateSetter setState) {
      final query = searchController.text.trim();

      final queryWords = query
          .toLowerCase()
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList();

      final filtered = favoriteProducts
          .where((product) {
            if (queryWords.isEmpty) return true;
            final combined =
                '${product['name'] ?? ''} ${product['brand'] ?? ''}'
                    .toLowerCase();
            return queryWords.every((word) => combined.contains(word));
          })
          .take(50)
          .toList();

      setState(() {
        results
          ..clear()
          ..addAll(filtered);
      });
    }

    if (!mounted) return null;

    final user = _supabase.auth.currentUser;
    if (user == null) return null;

    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            if (favoriteProducts.isEmpty && !isLoading) {
              isLoading = true;
              _supabase
                  .from('favorites')
                  .select('products(code, name, brand, p, kcal)')
                  .eq('user_id', user.id)
                  .then((rows) {
                    if (!context.mounted) return;
                    final loaded = (rows as List)
                        .map((e) => e['products'])
                        .where((p) => p != null)
                        .map((p) => Map<String, dynamic>.from(p as Map))
                        .toList();

                    setState(() {
                      favoriteProducts
                        ..clear()
                        ..addAll(loaded);
                      isLoading = false;
                    });
                    search(setState);
                  })
                  .catchError((_) {
                    if (!context.mounted) return;
                    setState(() => isLoading = false);
                  });
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: 440,
                child: Column(
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search in your favorites',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => search(setState),
                    ),
                    const SizedBox(height: 10),
                    if (isLoading) const LinearProgressIndicator(),
                    const SizedBox(height: 6),
                    Expanded(
                      child: results.isEmpty
                          ? const Center(
                              child: Text('No matching favorite products.'),
                            )
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (context, index) {
                                final product = results[index];
                                return ListTile(
                                  title: Text(
                                    (product['name'] ?? '').toString(),
                                  ),
                                  subtitle: Text(
                                    '${product['brand'] ?? ''}  •  ${(product['p'] ?? 0).toString()}g/100g',
                                  ),
                                  onTap: () => Navigator.pop(ctx, product),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<double?> _askForGrams() async {
    final controller = TextEditingController(text: '100');
    if (!mounted) return null;

    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Amount in grams'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Grams',
            hintText: 'e.g. 150',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(
                controller.text.replaceAll(',', '.'),
              );
              if (parsed == null || parsed <= 0) return;
              Navigator.pop(ctx, parsed);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = _supabase.auth.currentUser?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipes'),
        actions: [
          IconButton(onPressed: _loadRecipes, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateRecipeDialog,
        icon: const Icon(Icons.add),
        label: const Text('Build recipe'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recipes.isEmpty
          ? const Center(child: Text('No recipes yet. Create the first one.'))
          : ListView.builder(
              itemCount: _recipes.length,
              itemBuilder: (context, index) {
                final recipe = _recipes[index];
                final recipeId = (recipe['id'] ?? '').toString();
                final isMine = recipe['owner_id'] == currentUserId;
                final isPublic = recipe['is_public'] == true;
                final liked = _likedRecipeIds.contains(recipeId);

                final num protein = (recipe['protein_total_g'] as num?) ?? 0;
                final num kcal = (recipe['kcal_total'] as num?) ?? 0;
                final num score = (recipe['score'] as num?) ?? 0;
                final num likes = (recipe['like_count'] as num?) ?? 0;

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    title: Text(
                      (recipe['title'] ?? 'Untitled recipe').toString(),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'By ${(recipe['owner_name'] ?? 'User').toString()}',
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${protein.toStringAsFixed(1)}g protein • ${kcal.toStringAsFixed(0)} kcal • score ${score.toStringAsFixed(1)}',
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatCentPerProtein(recipe['cent_per_g_protein']),
                        ),
                      ],
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        InkWell(
                          onTap: () => _toggleLike(recipe),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                liked ? Icons.favorite : Icons.favorite_border,
                                color: Colors.red,
                              ),
                              const SizedBox(width: 4),
                              Text(likes.toString()),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (isMine)
                          GestureDetector(
                            onTap: () => _togglePrivacy(recipe),
                            child: Text(
                              isPublic ? 'Public' : 'Private',
                              style: TextStyle(
                                fontSize: 12,
                                color: isPublic ? Colors.green : Colors.orange,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        else
                          Text(
                            isPublic ? 'Public' : 'Private',
                            style: TextStyle(
                              fontSize: 12,
                              color: isPublic ? Colors.green : Colors.orange,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
