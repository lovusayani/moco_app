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

/// Edits the fields the backend actually accepts on `PATCH /users/me`
/// (displayName, language, gender) — no field is invented here that the
/// server would silently ignore. Reuses the same API the initial profile
/// setup screen uses, so the two can never validate a name differently.
///
/// Gender has no backend lock — `PATCH /users/me` accepts a change at any
/// time — so none is added here either; inventing a restriction the server
/// does not enforce would only teach the client to disagree with it.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key, this.startWithListenerApplication = false});

  /// True when reached from "Apply to become a listener" — expands that
  /// section immediately instead of requiring a second tap.
  final bool startWithListenerApplication;

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _nameController;
  late String _language;
  String? _gender;
  late bool _applyAsListener;
  bool _busy = false;
  String? _error;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authControllerProvider).user;
    _nameController = TextEditingController(text: user?.displayName ?? '');
    _language = user?.language ?? 'en';
    _gender = user?.gender;
    _applyAsListener = widget.startWithListenerApplication;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

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

      final user = ref.read(authControllerProvider).user;
      if (_applyAsListener && !(user?.canBeListener ?? false)) {
        await ref.read(usersApiProvider).becomeListener();
        await auth.refreshUser();
      }

      if (!mounted) return;
      setState(() => _busy = false);
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
        _nameError = e.fieldErrors['displayName'];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).user;
    final alreadyListener = user?.canBeListener ?? false;

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Edit profile'),
      ),
      body: MocoBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Name',
                  style: TextStyle(color: MocoColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: MocoSpacing.sm),
                TextField(
                  key: const Key('edit_profile_name'),
                  controller: _nameController,
                  enabled: !_busy,
                  style: const TextStyle(color: MocoColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Your name',
                    errorText: _nameError,
                  ),
                ),
                const SizedBox(height: MocoSpacing.xl),
                const Text(
                  'Language',
                  style: TextStyle(color: MocoColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: MocoSpacing.sm),
                Wrap(
                  spacing: MocoSpacing.sm,
                  children: _languages.entries
                      .map(
                        (e) => MocoChip(
                          key: Key('edit_profile_lang_${e.key}'),
                          label: e.value,
                          selected: _language == e.key,
                          onTap: _busy ? null : () => setState(() => _language = e.key),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: MocoSpacing.xl),
                const Text(
                  'Gender',
                  style: TextStyle(color: MocoColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: MocoSpacing.sm),
                Wrap(
                  spacing: MocoSpacing.sm,
                  children: _genders.entries
                      .map(
                        (e) => MocoChip(
                          key: Key('edit_profile_gender_${e.key}'),
                          label: e.value,
                          selected: _gender == e.key,
                          onTap: _busy ? null : () => setState(() => _gender = e.key),
                        ),
                      )
                      .toList(),
                ),
                if (!alreadyListener) ...[
                  const SizedBox(height: MocoSpacing.xl),
                  MocoGlassCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Apply to become a listener',
                                style: TextStyle(
                                  color: MocoColors.textPrimary,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Verification is required before you can go online.',
                                style: TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: const Key('edit_profile_apply_listener'),
                          value: _applyAsListener,
                          onChanged: _busy ? null : (v) => setState(() => _applyAsListener = v),
                          activeThumbColor: MocoColors.accentPrimary,
                        ),
                      ],
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: MocoSpacing.md),
                  Text(
                    _error!,
                    key: const Key('edit_profile_error'),
                    style: const TextStyle(color: MocoColors.danger, fontSize: 13),
                  ),
                ],
                const SizedBox(height: MocoSpacing.xl),
                MocoPrimaryButton(
                  key: const Key('edit_profile_save'),
                  label: 'Save',
                  loading: _busy,
                  onPressed: _busy ? null : _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
