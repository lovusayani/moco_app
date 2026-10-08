import 'package:flutter/material.dart';

import '../../core/widgets/moco_states.dart';

/// Web only: the top bar's Live item. Deliberately an empty state for now —
/// no rooms, streaming or backend behind it yet.
class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      bottom: false,
      child: Padding(
        // Clears the web top bar above and the floating nav below.
        padding: EdgeInsets.only(top: 64, bottom: 96),
        child: MocoEmptyState(
          key: Key('live_empty'),
          title: 'Nothing live yet',
          message: 'Live is coming soon. Check back later.',
          icon: Icons.sensors_rounded,
        ),
      ),
    );
  }
}
