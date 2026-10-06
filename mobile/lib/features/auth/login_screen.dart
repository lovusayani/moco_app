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
import '../../shared/models/app_config.dart';

enum _Step { identify, code }

/// Login and registration in one: a one-time code by email (the default) or,
/// where the backend offers them, SMS, WhatsApp or Telegram.
///
/// Nothing here fakes a success: the session only exists once the backend
/// returns a token, and a method the backend has not configured cannot be
/// selected. Codes are single-use and rate limited server-side, so the UI
/// never auto-retries a failed verify — that would spend the user's remaining
/// attempts for them. Whether the account is new is decided by the backend
/// and never shown here; profile setup follows through the normal routing.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  _Step _step = _Step.identify;

  /// The method the user picked; null means "the default" (email).
  OtpChannel? _picked;

  /// What the code was sent to — kept so verify and resend use exactly it.
  OtpChannel? _sentChannel;
  String? _sentTo;

  bool _busy = false;
  String? _error;
  int _resendIn = 0;
  Timer? _resendTimer;

  // India-first, matching the target market. Kept as a constant rather than a
  // picker until the product ships outside +91.
  static const _dialCode = '+91';
  static const _maxFormWidth = 420.0;

  static final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  @override
  void dispose() {
    _resendTimer?.cancel();
    _emailController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  AuthConfig get _auth => ref
      .watch(appConfigProvider)
      .maybeWhen(data: (c) => c.auth, orElse: () => const AuthConfig());

  OtpChannel get _channel => _picked ?? OtpChannel.email;

  String get _identifier => _channel.usesPhone
      ? '$_dialCode${_phoneController.text.trim()}'
      : _emailController.text.trim();

  bool get _identifierValid => _channel.usesPhone
      ? _phoneController.text.trim().length == 10
      : _emailPattern.hasMatch(_emailController.text.trim());

  bool get _codeValid => _codeController.text.trim().length == 6;

  void _startResendTimer(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendIn = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  /// Short, human messages. Provider and server internals never reach here.
  String _message(ApiException e, OtpChannel channel) {
    switch (e.code) {
      case 'otp_expired':
        return 'Code expired. Request a new one.';
      case 'otp_cooldown':
        return e.message;
      case 'otp_delivery_failed':
        return channel == OtpChannel.email
            ? 'Unable to send email. Please try again later.'
            : 'Unable to send the code. Please try again later.';
      case 'channel_unavailable':
        return 'This method is not available right now. Please use email.';
      case 'invalid_email':
        return 'Enter a valid email address.';
      case 'invalid_phone':
        return 'Enter a valid 10-digit mobile number.';
    }
    if (e.kind == ApiErrorKind.rateLimited) {
      return 'Too many attempts. Please try again later.';
    }
    if (e.kind == ApiErrorKind.unauthorized) return 'Invalid code';
    return e.message;
  }

  Future<void> _send({required bool resend}) async {
    final channel = resend ? _sentChannel! : _channel;
    final identifier = resend ? _sentTo! : _identifier;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final sent = await ref
          .read(authActionsProvider)
          .requestOtp(channel: channel, identifier: identifier);
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _sentChannel = channel;
        _sentTo = identifier;
        _busy = false;
        if (resend) _codeController.clear();
      });
      _startResendTimer(sent.resendIn);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _message(e, channel);
      });
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(authActionsProvider)
          .verifyOtp(
            channel: _sentChannel!,
            identifier: _sentTo!,
            code: _codeController.text.trim(),
          );
      // No manual navigation: the router redirect reacts to the auth change and
      // sends the user to profile setup or discovery as appropriate.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // A spent code cannot be retried, so clear it for a fresh request.
        if (e.code == 'otp_expired') _codeController.clear();
        _error = _message(e, _sentChannel!);
      });
    }
  }

  void _backToIdentify() {
    setState(() {
      _step = _Step.identify;
      _error = null;
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.calm,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const pad = MocoSpacing.screenPadding;
              // Centred both ways when there is room; scrolls (e.g. under the
              // keyboard) when there is not.
              return SingleChildScrollView(
                padding: const EdgeInsets.all(pad),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 2 * pad).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _maxFormWidth,
                      ),
                      child: Column(
                        key: const Key('login_form'),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _step == _Step.identify
                            ? _identifyStep()
                            : _codeStep(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _identifyStep() {
    final auth = _auth;
    return [
      Text('Login / Registration', style: _titleStyle),
      const SizedBox(height: MocoSpacing.sm),
      Text(
        'Sign in or create your account with a one-time code.',
        style: _subtitleStyle,
      ),
      const SizedBox(height: MocoSpacing.xl),
      _ChannelSelector(
        selected: _channel,
        isAvailable: auth.isAvailable,
        onSelect: (c) => setState(() {
          _picked = c;
          _error = null;
        }),
      ),
      const SizedBox(height: MocoSpacing.lg),
      if (_channel.usesPhone) _phoneField() else _emailField(),
      if (_error != null) ...[
        const SizedBox(height: MocoSpacing.lg),
        _ErrorBanner(message: _error!),
      ],
      const SizedBox(height: MocoSpacing.xl),
      MocoPrimaryButton(
        key: const Key('login_send_code'),
        label: 'Send OTP',
        loading: _busy,
        onPressed: _identifierValid && auth.isAvailable(_channel)
            ? () => _send(resend: false)
            : null,
      ),
    ];
  }

  List<Widget> _codeStep() {
    final channel = _sentChannel!;
    final via = switch (channel) {
      OtpChannel.email => null,
      OtpChannel.sms => 'by SMS',
      OtpChannel.whatsapp => 'on WhatsApp',
      OtpChannel.telegram => 'on Telegram',
    };
    return [
      Text('Enter the code', style: _titleStyle),
      const SizedBox(height: MocoSpacing.sm),
      Text('We sent a verification code to', style: _subtitleStyle),
      const SizedBox(height: 2),
      Text(
        via == null ? _sentTo! : '$_sentTo $via',
        key: const Key('login_sent_to'),
        style: TextStyle(
          color: MocoColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: MocoSpacing.xl),
      _codeField(),
      if (_error != null) ...[
        const SizedBox(height: MocoSpacing.lg),
        _ErrorBanner(message: _error!),
      ],
      const SizedBox(height: MocoSpacing.xl),
      MocoPrimaryButton(
        key: const Key('login_verify'),
        label: 'Verify',
        loading: _busy,
        onPressed: _codeValid ? _verify : null,
      ),
      const SizedBox(height: MocoSpacing.lg),
      Text(
        "Didn't receive it?",
        textAlign: TextAlign.center,
        style: TextStyle(color: MocoColors.textMuted, fontSize: 13),
      ),
      TextButton(
        key: const Key('login_resend'),
        onPressed: _resendIn > 0 || _busy ? null : () => _send(resend: true),
        child: Text(
          _resendIn > 0 ? 'Resend code in ${_resendIn}s' : 'Resend code',
          style: TextStyle(
            color: _resendIn > 0 ? MocoColors.textMuted : MocoColors.accentSoft,
          ),
        ),
      ),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            key: const Key('login_change_identifier'),
            onPressed: _busy ? null : _backToIdentify,
            child: Text(
              channel.usesPhone ? 'Change number' : 'Change email',
              style: TextStyle(color: MocoColors.textMuted),
            ),
          ),
          Text('·', style: TextStyle(color: MocoColors.textMuted)),
          TextButton(
            key: const Key('login_change_method'),
            onPressed: _busy ? null : _backToIdentify,
            child: Text(
              'Use another method',
              style: TextStyle(color: MocoColors.textMuted),
            ),
          ),
        ],
      ),
    ];
  }

  TextStyle get _titleStyle => TextStyle(
    color: MocoColors.textPrimary,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );

  TextStyle get _subtitleStyle =>
      TextStyle(color: MocoColors.textSecondary, fontSize: 15);

  Widget _emailField() {
    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
      child: TextField(
        key: const Key('login_email_field'),
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (_identifierValid && !_busy) _send(resend: false);
        },
        style: TextStyle(color: MocoColors.textPrimary, fontSize: 17),
        decoration: const InputDecoration(
          labelText: 'Email address',
          hintText: 'you@example.com',
          border: InputBorder.none,
          // The theme's outlined borders would draw a box inside the card.
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          contentPadding: EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _phoneField() {
    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
      child: Row(
        children: [
          Text(
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
              autofillHints: const [AutofillHints.telephoneNumberNational],
              maxLength: 10,
              onChanged: (_) => setState(() {}),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 17,
                letterSpacing: 1.2,
              ),
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                hintText: '98765 43210',
                counterText: '',
                border: InputBorder.none,
                // The theme's outlined borders would draw a box inside the card.
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
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
        autofillHints: const [AutofillHints.oneTimeCode],
        autofocus: true,
        maxLength: 6,
        textAlign: TextAlign.center,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (_codeValid && !_busy) _verify();
        },
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: TextStyle(
          color: MocoColors.textPrimary,
          fontSize: 26,
          fontWeight: FontWeight.w600,
          letterSpacing: 12,
        ),
        decoration: const InputDecoration(
          hintText: '••••••',
          counterText: '',
          border: InputBorder.none,
          // The theme's outlined borders would draw a box inside the card.
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          contentPadding: EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }
}

/// Email | SMS | WhatsApp | Telegram. Methods the backend has not configured
/// are shown but cannot be selected ("Soon").
class _ChannelSelector extends StatelessWidget {
  const _ChannelSelector({
    required this.selected,
    required this.isAvailable,
    required this.onSelect,
  });

  final OtpChannel selected;
  final bool Function(OtpChannel) isAvailable;
  final ValueChanged<OtpChannel> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        children: [
          for (final channel in OtpChannel.values)
            Expanded(child: _segment(channel)),
        ],
      ),
    );
  }

  Widget _segment(OtpChannel channel) {
    final available = isAvailable(channel);
    final isSelected = channel == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      enabled: available,
      label: available ? channel.label : '${channel.label}, coming soon',
      child: InkWell(
        key: Key('login_channel_${channel.name}'),
        borderRadius: BorderRadius.circular(MocoRadius.sm),
        onTap: available && !isSelected ? () => onSelect(channel) : null,
        child: AnimatedContainer(
          duration: MocoDuration.tab,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? MocoColors.surfaceGlassStrong
                : Colors.transparent,
            borderRadius: BorderRadius.circular(MocoRadius.sm),
            border: isSelected
                ? Border.all(color: MocoColors.accentSoft)
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                channel.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  color: !available
                      ? MocoColors.textMuted.withValues(alpha: 0.6)
                      : isSelected
                      ? MocoColors.textPrimary
                      : MocoColors.textSecondary,
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (!available)
                Text(
                  'Soon',
                  style: TextStyle(
                    color: MocoColors.textMuted.withValues(alpha: 0.6),
                    fontSize: 10,
                  ),
                ),
            ],
          ),
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
          Icon(Icons.error_outline_rounded, color: MocoColors.danger, size: 19),
          const SizedBox(width: MocoSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: MocoColors.danger, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
