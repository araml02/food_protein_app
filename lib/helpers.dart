import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Helper functies shared tussen SearchPage, DiscoverPage en FavoritesPage

double getMinPricePerGram(Map product) {
  double min = double.infinity;
  List prices = product['prices'] ?? [];
  double proteinPer100 = (product['p'] ?? 0).toDouble();
  if (proteinPer100 <= 0) return double.infinity;

  for (var pr in prices) {
    double pricePerPack = (pr['price'] ?? 0).toDouble();
    double packWeight = (pr['pack_weight_grams'] ?? 100).toDouble();
    
    double totalProteinInPack = (proteinPer100 / 100) * packWeight;
    double pricePerGramProtein = pricePerPack / totalProteinInPack;
    
    if (pricePerGramProtein < min) min = pricePerGramProtein;
  }
  return min;
}

Widget buildStat(String val, String lab, Color col) => Column(children: [
  Text(val, style: TextStyle(color: col, fontSize: 22, fontWeight: FontWeight.bold)),
  Text(lab, style: const TextStyle(fontWeight: FontWeight.w500))
]);

Widget buildScoreCircle(double score) {
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
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: progress,
            backgroundColor: Colors.grey[300],
            valueColor: AlwaysStoppedAnimation(scoreColor),
            strokeWidth: 4,
          ),
        ),
        Text(
          score.toStringAsFixed(1),
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: scoreColor),
        ),
      ],
    ),
  );
}

Future<void> submitPrice(
  BuildContext context,
  SupabaseClient supabase,
  String code,
  double price,
  String store,
  double weight,
  Function onSuccess,
) async {
  try {
    await supabase.from('prices').insert({
      'product_code': code,
      'price': price,
      'store_name': store,
      'pack_weight_grams': weight,
    });
    onSuccess();
    if (context.mounted) Navigator.pop(context);
  } catch (e) {
    debugPrint("Error: $e");
  }
}

void showPriceDialog(
  BuildContext context,
  String code,
  SupabaseClient supabase,
  Function(String, double, String, double) onSubmit,
) {
  final priceCont = TextEditingController();
  final weightCont = TextEditingController(text: "500");
  String store = "Albert Heijn";
  
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text("Prijs & Gewicht melden"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: priceCont,
            decoration: const InputDecoration(labelText: "Prijs (€)", hintText: "bijv. 1.50"),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: weightCont,
            decoration: const InputDecoration(labelText: "Gewicht van verpakking (gram)", hintText: "bijv. 500"),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: store,
            items: ["Albert Heijn", "Jumbo", "Delhaize", "Aldi", "Lidl", "Colruyt"]
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) => store = v!,
            decoration: const InputDecoration(labelText: "Winkel"),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: () {
            final p = double.tryParse(priceCont.text.replaceFirst(',', '.'));
            final w = double.tryParse(weightCont.text.replaceFirst(',', '.'));
            if (p != null && w != null) {
              onSubmit(code, p, store, w);
            }
          },
          child: const Text("Save"),
        ),
      ],
    ),
  );
}

void showDetailsBottomSheet(
  BuildContext context,
  Map<String, dynamic> prod,
  SupabaseClient supabase,
  Function(String) onShowPriceDialog, {
  bool showAddPriceButton = true,
}) {
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
          Text(
            prod['brand'] ?? 'Unknown brand',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              buildStat("${protein.toStringAsFixed(1)}g", "Protein", Colors.green),
              buildStat("${kcal.toStringAsFixed(1)}", "Kcal", Colors.blue),
              buildStat(ratio, "Ratio", Colors.purple),
            ],
          ),
          const Divider(height: 40),
          const Text(
            "User Prices",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (prices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text("No prices reported yet."),
            ),
          ...prices.map((pr) {
            final DateTime updatedAt = DateTime.parse(pr['created_at']);
            final int daysAgo = DateTime.now().difference(updatedAt).inDays;
            
            Color statusColor = daysAgo <= 7
                ? Colors.green
                : (daysAgo <= 30 ? Colors.orange : Colors.red);
            String statusText =
                daysAgo == 0 ? "Verified today" : "Verified $daysAgo days ago";

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
                title: Text(
                  "${pr['store_name']} (${pr['pack_weight_grams'] ?? 100}g)",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "€${pr['price'].toStringAsFixed(2)}",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.check_circle, color: Colors.blue),
                      onPressed: () async {
                        await supabase
                            .from('prices')
                            .update({'created_at': DateTime.now().toIso8601String()})
                            .eq('id', pr['id']);
                        if (ctx.mounted) Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Thanks for verifying!")),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 20),
          if (showAddPriceButton)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => onShowPriceDialog(prod['code']),
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
