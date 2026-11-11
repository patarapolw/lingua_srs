import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../views/activity_heatmap_view.dart';
import '../views/recent_ai_discussions_view.dart';
import '../views/lesson_list_view.dart';
import '../views/sentence_pool_view.dart';
import '../views/vocab_pool_view.dart';

class AdaptiveScaffold extends StatefulWidget {
  final VoidCallback? onToggleTheme;
  final bool isDarkMode;

  const AdaptiveScaffold({
    super.key,
    this.onToggleTheme,
    this.isDarkMode = false,
  });

  @override
  State<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends State<AdaptiveScaffold> {
  int _selectedIndex = 0;
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectTab(int index, {required bool isDesktop}) {
    setState(() => _selectedIndex = index);
    if (!isDesktop && _pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 800;
    final theme = Theme.of(context);
    final showAi = context.select<AppProvider, bool>((p) => p.showAi);

    final pages = [
      LessonListView(
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: widget.isDarkMode,
        // The rail has a tab for it.
        showStudyActivity: !isDesktop,
      ),
      const VocabPoolView(),
      const SentencePoolView(),
      if (showAi) const RecentAiDiscussionsView(),
      // Study activity is a tab on the desktop rail only: the bottom bar has
      // no room for a fifth, so there it stays in the Lessons ⋮ menu. Last,
      // so the other tabs keep their place when the window changes layout.
      if (isDesktop) const ActivityHeatmapView(),
    ];
    // The Discussions tab goes away when AI features are turned off, and
    // Study activity when the window narrows to the mobile layout.
    if (_selectedIndex >= pages.length) _selectedIndex = 0;

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (idx) => _selectTab(idx, isDesktop: true),
              extended: MediaQuery.of(context).size.width >= 1100,
              leading: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.auto_stories_rounded,
                        color: theme.colorScheme.onPrimaryContainer,
                        size: 24,
                      ),
                    ),
                    if (MediaQuery.of(context).size.width >= 1100) ...[
                      const SizedBox(width: 12),
                      Text(
                        'LinguaSRS',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: IconButton(
                      icon: Icon(
                        widget.isDarkMode ? Icons.light_mode : Icons.dark_mode,
                      ),
                      tooltip: widget.isDarkMode
                          ? 'Switch to Light'
                          : 'Switch to Dark',
                      onPressed: widget.onToggleTheme,
                    ),
                  ),
                ),
              ),
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.library_books_outlined),
                  selectedIcon: Icon(Icons.library_books),
                  label: Text('Lessons'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.translate_outlined),
                  selectedIcon: Icon(Icons.translate),
                  label: Text('Vocab Pool'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.format_quote_outlined),
                  selectedIcon: Icon(Icons.format_quote),
                  label: Text('Sentence Pool'),
                ),
                if (showAi)
                  const NavigationRailDestination(
                    icon: Icon(Icons.forum_outlined),
                    selectedIcon: Icon(Icons.forum),
                    label: Text('Recent Discussions'),
                  ),
                const NavigationRailDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  selectedIcon: Icon(Icons.calendar_month),
                  label: Text('Study activity'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages[_selectedIndex]),
          ],
        ),
      );
    }

    // Mobile Layout: Bottom Navigation Bar
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _selectedIndex = index),
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => _selectTab(idx, isDesktop: false),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Lessons',
          ),
          const NavigationDestination(
            icon: Icon(Icons.translate_outlined),
            selectedIcon: Icon(Icons.translate),
            label: 'Vocab',
          ),
          const NavigationDestination(
            icon: Icon(Icons.format_quote_outlined),
            selectedIcon: Icon(Icons.format_quote),
            label: 'Sentences',
          ),
          if (showAi)
            const NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: 'Discussions',
            ),
        ],
      ),
    );
  }
}
