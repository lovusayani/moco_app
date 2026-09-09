import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';

const _languages = {'en': 'English', 'hi': 'हिंदी', 'te': 'తెలుగు'};
const _genders = {'female': 'Female', 'male': 'Male', 'other': 'Other'};

/// Profile setup, required before the app shell opens.
///
/// The listener application is collapsed by default and entirely optional: a
/// normal user must never be made to fill in KYC-adjacent fields to finish
/// signing up.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _nameController = TextEditingController();

  String _language = 'en';
  String? _gender;
  bool _applyAsListener = false;
  bool _busy = false;
  String? _error;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authControllerProvider).user;
    if (user != null) {
      _nameController.text = user.displayName ?? '';
      _language = user.language;
      _gender = user.gender;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Mirrors the backend's own rule: display name 2–40 characters.
  String? _validateName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Please enter your name';
    if (trimmed.length < 2) return 'Name must be at least 2 characters';
    if (trimmed.length > 40) return 'Name must be 40 characters or fewer';
    return null;
  }

  Future<void> _save() async {
    final nameError = _validateName(_nameController.text);
    if (nameError != null) {
      setState(() => _nameError = nameError);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _nameError = null;
    });

    try {
      final auth = ref.read(authActionsProvider);
      await auth.updateProfile(
        displayName: _nameController.text.trim(),
        language: _language,
        gender: _gender,
      );

      // Opting in is a separate backend call, and only when explicitly asked.
      if (_applyAsListener) {
        await ref.read(usersApiProvider).becomeListener();
        await auth.refreshUser();
      }
      // Routing reacts to the auth state change; no manual navigation here.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
        // Surface field-level validation against the field it belongs to.
        _nameError = e.fieldErrors['displayName'];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.calm,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: MocoSpacing.xl),
                const Text(
                  'Set up your profile',
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: MocoSpacing.sm),
                const Text(
                  'This is how other people will see you.',
                  style: TextStyle(
                    color: MocoColors.textSecondary,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: MocoSpacing.xl),

                const _FieldLabel('Your name'),
                const SizedBox(height: MocoSpacing.sm),
                TextField(
                  key: const Key('profile_name_field'),
                  controller: _nameController,
                  maxLength: 40,
                  style: const TextStyle(color: MocoColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Rahul',
                    counterText: '',
                    errorText: _nameError,
                  ),
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
                const SizedBox(height: MocoSpacing.xl),

                const _FieldLabel('Language'),
                const SizedBox(height: MocoSpacing.sm),
                Wrap(
                  spacing: MocoSpacing.sm,
                  runSpacing: MocoSpacing.sm,
                  children: _languages.entries
                      .map(
                        (e) => MocoChip(
                          label: e.value,
                          selected: _language == e.key,
                          onTap: () => setState(() => _language = e.key),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: MocoSpacing.xl),

                const _FieldLabel('Gender'),
                const SizedBox(height: MocoSpacing.sm),
                Wrap(
                  spacing: MocoSpacing.sm,
                  runSpacing: MocoSpacing.sm,
                  children: _genders.entries
                      .map(
                        (e) => MocoChip(
                          label: e.value,
                          selected: _gender == e.key,
                          onTap: () => setState(() => _gender = e.key),
                        ),
                      )
                      .toList(),
                ),

                const SizedBox(height: MocoSpacing.xl),
                _ListenerApplication(
                  expanded: _applyAsListener,
                  onToggle: (v) => setState(() => _applyAsListener = v),
                ),

                if (_error != null) ...[
                  const SizedBox(height: MocoSpacing.lg),
                  Text(
                    _error!,
                    key: const Key('profile_error'),
                    style: const TextStyle(
                      color: MocoColors.danger,
                      fontSize: 13.5,
                    ),
                  ),
                ],

                const SizedBox(height: MocoSpacing.xl),
                MocoPrimaryButton(
                  key: const Key('profile_save'),
                  label: 'Continue',
                  loading: _busy,
                  onPressed: _busy ? null : _save,
                ),
                const SizedBox(height: MocoSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: MocoColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

/// Collapsed listener application.
///
/// Expanding it only sets intent; the actual KYC submission (name, ID document,
/// UPI) is a separate screen in a later phase. All this does is call
/// `POST /users/me/become-listener`, which creates an unverified profile.
class _ListenerApplication extends StatelessWidget {
  const _ListenerApplication({required this.expanded, required this.onToggle});

  final bool expanded;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      glow: expanded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(MocoRadius.sm),
                  color: MocoColors.coinAccent.withValues(alpha: 0.16),
                ),
                child: const Icon(
                  Icons.headset_mic_rounded,
                  size: 19,
                  color: MocoColors.coinAccent,
                ),
              ),
              const SizedBox(width: MocoSpacing.md),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Apply to become a listener',
                      style: TextStyle(
                        color: MocoColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Optional — earn for your time',
                      style: TextStyle(
                        color: MocoColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const Key('profile_listener_toggle'),
                value: expanded,
                onChanged: onToggle,
                activeThumbColor: MocoColors.accentPrimary,
              ),
            ],
          ),
          AnimatedSize(
            duration: MocoDuration.sheet,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? const Padding(
                    padding: EdgeInsets.only(top: MocoSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(height: MocoSpacing.xl),
                        Text(
                          'We will create your listener profile. Before you '
                          'can go online and take calls you will need to '
                          'complete identity verification, which a person '
                          'reviews.',
                          style: TextStyle(
                            color: MocoColors.textSecondary,
                            fontSize: 13.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
