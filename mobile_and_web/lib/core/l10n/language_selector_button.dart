import 'package:flutter/material.dart';

import 'language_provider.dart';

/// Her ekranda (Giriş, Yönetici, Kurye, Takip ve İlk Açılış)
/// anında dil değiştirmeyi sağlayan şık buton ve seçim diyaloğu.
class LanguageSelectorButton extends StatelessWidget {
  final LanguageProvider? languageProvider;
  final bool compact;
  final Color? color;

  const LanguageSelectorButton({
    super.key,
    this.languageProvider,
    this.compact = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final lp = languageProvider ?? LanguageScope.maybeOf(context);
    if (lp == null) return const SizedBox.shrink();
    final current = lp.currentLanguage;

    if (compact) {
      return IconButton(
        icon: Text(
          '${current.flag} 🌐',
          style: const TextStyle(fontSize: 16),
        ),
        tooltip: current.name,
        onPressed: () => showLanguageDialog(context, lp),
      );
    }

    return InkWell(
      onTap: () => showLanguageDialog(context, lp),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (color ?? Theme.of(context).primaryColor).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (color ?? Theme.of(context).primaryColor).withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current.flag, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 6),
            Text(
              current.name,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color ?? Theme.of(context).primaryColor,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: color ?? Theme.of(context).primaryColor,
            ),
          ],
        ),
      ),
    );
  }

  static void showLanguageDialog(
    BuildContext context,
    LanguageProvider languageProvider,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Row(
                children: [
                  Icon(Icons.language_rounded, color: Color(0xFF1E40AF)),
                  SizedBox(width: 10),
                  Text(
                    'Language / Dil / اللغة',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: LanguageProvider.supportedLanguages.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, index) {
                    final item = LanguageProvider.supportedLanguages[index];
                    final isSelected =
                        item.code == languageProvider.currentCode;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      leading: Text(
                        item.flag,
                        style: const TextStyle(fontSize: 24),
                      ),
                      title: Text(
                        item.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected
                              ? const Color(0xFF1E40AF)
                              : const Color(0xFF1E293B),
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(
                              Icons.check_circle_rounded,
                              color: Color(0xFF1E40AF),
                            )
                          : null,
                      onTap: () async {
                        Navigator.pop(ctx);
                        await languageProvider.setLanguage(item.code);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
