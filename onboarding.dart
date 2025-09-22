import 'package:flutter/material.dart';

/// OnboardingFlow:
/// 1) เลือกภาษา (ใช้ภาพ 1.png เป็นภาพประกอบ)
/// 2) สไลด์ 4 หน้า:
///    - EN ใช้ภาพ 2-5.png (จบที่หน้า 5)
///    - TH ใช้ภาพ 6-9.png (จบที่หน้า 9)
///
/// โค้ดไม่ผูก storage ตรง ๆ — ให้ main.dart ส่ง callback เข้ามา
class OnboardingFlow extends StatefulWidget {
  final String? initialLang; // 'th' | 'en' | null
  final Future<void> Function(String lang) onPickLanguage;
  final Future<void> Function() onMarkSeen;
  final VoidCallback onFinish;

  const OnboardingFlow({
    super.key,
    this.initialLang,
    required this.onPickLanguage,
    required this.onMarkSeen,
    required this.onFinish,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  String? _lang;

  @override
  void initState() {
    super.initState();
    _lang = widget.initialLang; // ถ้าโหลดได้แล้วให้ข้ามหน้าเลือกภาษา
  }

  @override
  Widget build(BuildContext context) {
    // ยังไม่เลือกภาษา → หน้าเลือกภาษา (โชว์ภาพ 1.png)
    if (_lang == null) {
      return LanguageSelectPage(
        onPicked: (code) async {
          await widget.onPickLanguage(code);
          if (!mounted) return;
          setState(() => _lang = code);
        },
      );
    }

    // เลือกแล้ว → ไป PageView ของภาษานั้น ๆ
    return IntroSlidesPage(
      lang: _lang!,
      onFinish: () async {
        await widget.onMarkSeen();
        if (!mounted) return;
        widget.onFinish(); // ใน main จะเช็คแล้วไป /home หรือ /login
      },
    );
  }
}

/// ---------------------------------------------------------------------------
/// หน้าเลือกภาษา (ภาพประกอบ = assets/images/1.png)
/// ---------------------------------------------------------------------------
class LanguageSelectPage extends StatelessWidget {
  final void Function(String langCode) onPicked;
  const LanguageSelectPage({super.key, required this.onPicked});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Text(
                'HereMe',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose your language\nกรุณาเลือกภาษาที่ต้องการ',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const Spacer(),
              // ภาพจาก Figma (หน้าเลือกภาษา)
              Image.asset(
                'assets/images/1.png',
                height: 220,
                fit: BoxFit.contain,
              ),
              const Spacer(),
              _LangTile(
                label: 'ภาษาไทย',
                subtitle: 'Thai',
                onTap: () => onPicked('th'),
              ),
              const SizedBox(height: 12),
              _LangTile(
                label: 'English',
                subtitle: 'English',
                onTap: () => onPicked('en'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _LangTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _LangTile({
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFFF6F9F7),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            const CircleAvatar(radius: 18, child: Icon(Icons.flag)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.titleMedium),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// สไลด์ Onboarding
/// - ถ้า lang == 'en' → ใช้ภาพ 2,3,4,5.png
/// - ถ้า lang == 'th' → ใช้ภาพ 6,7,8,9.png
/// ปุ่ม Next/Skip และหน้าสุดท้ายเป็น Start Now/เริ่มต้นใช้งาน
/// ---------------------------------------------------------------------------
class IntroSlidesPage extends StatefulWidget {
  final String lang; // 'th' | 'en'
  final VoidCallback onFinish;
  const IntroSlidesPage(
      {super.key, required this.lang, required this.onFinish});

  @override
  State<IntroSlidesPage> createState() => _IntroSlidesPageState();
}

class _IntroSlidesPageState extends State<IntroSlidesPage> {
  final _pc = PageController();
  int _idx = 0;

  late final List<String> _images = widget.lang == 'en'
      ? const [
          'assets/images/2.png',
          'assets/images/3.png',
          'assets/images/4.png',
          'assets/images/5.png', // จบ EN
        ]
      : const [
          'assets/images/6.png',
          'assets/images/7.png',
          'assets/images/8.png',
          'assets/images/9.png', // จบ TH
        ];

  void _next() {
    if (_idx < _images.length - 1) {
      _pc.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      widget.onFinish(); // จบหน้า 5 หรือ 9
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _idx == _images.length - 1;
    final th = widget.lang == 'th';

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _pc,
                  itemCount: _images.length,
                  onPageChanged: (i) => setState(() => _idx = i),
                  itemBuilder: (_, i) {
                    final img = _images[i];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(img, height: 420, fit: BoxFit.contain),
                        const SizedBox(height: 16),
                        _Dots(count: _images.length, index: _idx),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _next,
                            child: Text(
                              isLast
                                  ? (th ? 'เริ่มต้นใช้งาน' : 'Start Now')
                                  : (th ? 'ต่อไป' : 'Next'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: widget.onFinish,
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              minimumSize: const Size.fromHeight(48),
                            ),
                            child: Text(th ? 'ข้าม' : 'Skip'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;
  const _Dots({super.key, required this.count, required this.index});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: active ? 22 : 8,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
