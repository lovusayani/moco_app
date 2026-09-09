import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';

enum _Step { phone, code }

/// Phone + OTP sign-in against the real backend.
///
/// Nothing here fakes a success: the session only exists once the backend
/// returns a token. OTP codes are single-use and rate limited server-side, so
/// the UI never auto-retries a failed verify — that would spend the user's
/// remaining attempts for them.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  _Step _step = _Step.phone;
  bool _busy = false;
  String? _error;
  int _resendIn = 0;
  Timer? _resendTimer;

  // India-first, matching the target market. Kept as a constant rather than a
  // picker until the product ships outside +91.
  static const _dialCode = '+91';

  String get _e164 => '$_dialCode${_phoneController.text.trim()}';
  bool get _phoneValid => _phoneController.text.trim().length == 10;
  bool get _codeValid => _codeController.text.trim().length >= 4;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startResendTimer(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendIn = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  Future<void> _requestOtp() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final expiresIn = await ref.read(authActionsProvider).requestOtp(_e164);
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _busy = false;
      });
      // Offer resend at one minute, or sooner if the code expires first.
      _startResendTimer(expiresIn < 60 ? expiresIn : 60);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<void> _verifyOtp() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(authActionsProvider)
          .verifyOtp(phone: _e164, code: _codeController.text.trim());
      // No manual navigation: the router redirect reacts to the auth change and
      // sends the user to profile setup or discovery as appropriate.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // A spent code cannot be retried, so send the user back to request one.
        if (e.code == 'otp_expired') _codeController.clear();
        _error = e.message;
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
                const SizedBox(height: MocoSpacing.xxl),
                Text(
                  _step == _Step.phone ? 'Welcome to Moco' : 'Enter the code',
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: MocoSpacing.sm),
                Text(
                  _step == _Step.phone
                      ? 'We will text you a code to sign in.'
                      : 'Sent to $_e164',
                  style: const TextStyle(
                    color: MocoColors.textSecondary,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: MocoSpacing.xxl),
                if (_step == _Step.phone) _phoneField() else _codeField(),
                if (_error != null) ...[
                  const SizedBox(height: MocoSpacing.lg),
                  _ErrorBanner(message: _error!),
                ],
                const SizedBox(height: MocoSpacing.xl),
                if (_step == _Step.phone)
                  MocoPrimaryButton(
                    key: const Key('login_send_code'),
                    label: 'Send code',
                    loading: _busy,
                    onPressed: _phoneValid ? _requestOtp : null,
                  )
                else ...[
                  MocoPrimaryButton(
                    key: const Key('login_verify'),
                    label: 'Verify',
                    loading: _busy,
                    onPressed: _codeValid ? _verifyOtp : null,
                  ),
                  const SizedBox(height: MocoSpacing.md),
                  TextButton(
                    key: const Key('login_resend'),
                    onPressed: _resendIn > 0 || _busy ? null : _requestOtp,
                    child: Text(
                      _resendIn > 0
                          ? 'Resend code in ${_resendIn}s'
                          : 'Resend code',
                      style: TextStyle(
                        color: _resendIn > 0
                            ? MocoColors.textMuted
                            : MocoColors.accentSoft,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _step = _Step.phone;
                            _error = null;
                            _codeController.clear();
                          }),
                    child: const Text(
                      'Use a different number',
                      style: TextStyle(color: MocoColors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneField() {
    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
      child: Row(
        children: [
          const Text(
            _dialCode,
            style: TextStyle(
              color: MocoColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: MocoSpacing.md),
          Container(width: 1, height: 26, color: MocoColors.borderSubtle),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: TextField(
              key: const Key('login_phone_field'),
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              autofocus: true,
              maxLength: 10,
              onChanged: (_) => setState(() {}),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 17,
                letterSpacing: 1.2,
              ),
              decoration: const InputDecoration(
                hintText: '98765 43210',
                counterText: '',
                border: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeField() {
    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
      child: TextField(
        key: const Key('login_code_field'),
        controller: _codeController,
        keyboardType: TextInputType.number,
        autofocus: true,
        maxLength: 6,
        textAlign: TextAlign.center,
        onChanged: (_) => setState(() {}),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(
          color: MocoColors.textPrimary,
          fontSize: 26,
          fontWeight: FontWeight.w600,
          letterSpacing: 12,
        ),
        decoration: const InputDecoration(
          hintText: '••••••',
          counterText: '',
          border: InputBorder.none,
          filled: false,
          contentPadding: EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('login_error'),
      padding: const EdgeInsets.all(MocoSpacing.md),
      decoration: BoxDecoration(
        color: MocoColors.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: MocoColors.danger,
            size: 19,
          ),
          const SizedBox(width: MocoSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: MocoColors.danger, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
