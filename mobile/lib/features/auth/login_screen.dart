import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/widgets/moco_app_frame.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/app_config.dart';
import 'widgets/login_backdrop.dart';
import 'widgets/login_glass.dart';

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

  bool _fullBleed = false;

  @override
  void initState() {
    super.initState();
    // On web the login background fills the whole window, so the phone-width
    // app frame steps aside while this screen is up.
    if (ref.read(platformCapabilitiesProvider).isWeb) {
      _fullBleed = true;
      // After this frame: the frame is an ancestor mid-build right now.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => MocoAppFrame.fullBleedRequests.value++,
      );
    }
  }

  @override
  void dispose() {
    if (_fullBleed) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => MocoAppFrame.fullBleedRequests.value--,
      );
    }
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
    // The web app gets the immersive layout; Android keeps its own for now.
    // Same state, same _send/_verify — only the presentation differs.
    if (ref.watch(platformCapabilitiesProvider).isWeb) return _webScaffold();
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

  // ---------------------------------------------------------------- web

  static const _webMaxWidth = 360.0;

  LoginBackground? get _background => ref
      .watch(appConfigProvider)
      .maybeWhen(data: (c) => c.loginBackground, orElse: () => null);

  Widget _webScaffold() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          LoginBackdrop(background: _background),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Controls sit in the lower-middle; on short screens (or under
                // the keyboard) the column scrolls instead of overflowing.
                // Controls centred on the screen; on short screens (or under
                // the keyboard) the column scrolls instead of overflowing.
                const pad = 24.0;
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: pad,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - 2 * pad).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _webMaxWidth,
                            ),
                            child: AnimatedSwitcher(
                              duration: reduceMotion(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 380),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, anim) =>
                                  FadeTransition(
                                    opacity: anim,
                                    child: SlideTransition(
                                      position: Tween(
                                        begin: const Offset(0, 0.06),
                                        end: Offset.zero,
                                      ).animate(anim),
                                      child: child,
                                    ),
                                  ),
                              child: Column(
                                key: ValueKey(_step),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: _step == _Step.identify
                                    ? _webIdentifyStep()
                                    : _webCodeStep(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _webIdentifyStep() {
    final auth = _auth;
    // The first screen offers Email | SMS only.
    final channel = _channel == OtpChannel.sms
        ? OtpChannel.sms
        : OtpChannel.email;
    final motion = reduceMotion(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return [
      Entrance(
        child: GlassSegmented<OtpChannel>(
          key: const Key('login_form'),
          values: const [OtpChannel.email, OtpChannel.sms],
          selected: channel,
          labelOf: (c) => c == OtpChannel.email ? 'Email' : 'SMS',
          isEnabled: auth.isAvailable,
          keyOf: (c) => Key('login_channel_${c.name}'),
          onChanged: (c) => setState(() {
            _picked = c;
            _error = null;
          }),
        ),
      ),
      const SizedBox(height: 14),
      Entrance(
        delay: const Duration(milliseconds: 90),
        child: AnimatedSwitcher(
          duration: motion,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SizeTransition(
              sizeFactor: anim,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
          child: channel.usesPhone ? _webPhoneField() : _webEmailField(),
        ),
      ),
      if (_error != null) ...[const SizedBox(height: 12), _webError(_error!)],
      const SizedBox(height: 26),
      Entrance(
        delay: const Duration(milliseconds: 180),
        child: Center(
          child: PillActionButton(
            key: const Key('login_send_code'),
            semanticLabel: 'Send code',
            loading: _busy,
            onPressed: _identifierValid && auth.isAvailable(channel)
                ? () => _send(resend: false)
                : null,
          ),
        ),
      ),
    ];
  }

  List<Widget> _webCodeStep() {
    final channel = _sentChannel!;
    final caption = TextStyle(
      color: Colors.white.withValues(alpha: 0.78),
      fontSize: 14,
    );
    final link = TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 13.5,
    );
    return [
      Text(
        'Enter the code',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        channel.usesPhone ? 'Sent by SMS to $_sentTo' : 'Sent to $_sentTo',
        key: const Key('login_sent_to'),
        textAlign: TextAlign.center,
        style: caption,
      ),
      const SizedBox(height: 18),
      GlassSurface(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: TextField(
          key: const Key('login_code_field'),
          controller: _codeController,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          autofocus: true,
          maxLength: 6,
          textAlign: TextAlign.center,
          cursorColor: Colors.white,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_codeValid && !_busy) _verify();
          },
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: 10,
          ),
          decoration: _webInputDecoration('••••••'),
        ),
      ),
      if (_error != null) ...[const SizedBox(height: 12), _webError(_error!)],
      const SizedBox(height: 22),
      Center(
        child: PillActionButton(
          key: const Key('login_verify'),
          semanticLabel: 'Verify',
          loading: _busy,
          onPressed: _codeValid ? _verify : null,
        ),
      ),
      const SizedBox(height: 10),
      TextButton(
        key: const Key('login_resend'),
        onPressed: _resendIn > 0 || _busy ? null : () => _send(resend: true),
        child: Text(
          _resendIn > 0 ? 'Resend code in ${_resendIn}s' : 'Resend code',
          style: link.copyWith(
            color: _resendIn > 0
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white,
          ),
        ),
      ),
      TextButton(
        key: const Key('login_change_identifier'),
        onPressed: _busy ? null : _backToIdentify,
        child: Text(
          channel.usesPhone ? 'Change number' : 'Change email',
          style: link,
        ),
      ),
    ];
  }

  InputDecoration _webInputDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      color: Colors.white.withValues(alpha: 0.62),
      fontSize: 16,
    ),
    counterText: '',
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    filled: false,
    contentPadding: const EdgeInsets.symmetric(vertical: 16),
  );

  Widget _webEmailField() {
    return GlassSurface(
      key: const ValueKey('email'),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          Icon(
            Icons.mail_outline_rounded,
            color: Colors.white.withValues(alpha: 0.8),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('login_email_field'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              cursorColor: Colors.white,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_identifierValid && !_busy) _send(resend: false);
              },
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: _webInputDecoration('Type Email Id'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _webPhoneField() {
    return GlassSurface(
      key: const ValueKey('phone'),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Text(
            _dialCode,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 1,
            height: 22,
            color: Colors.white.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('login_phone_field'),
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumberNational],
              maxLength: 10,
              cursorColor: Colors.white,
              textInputAction: TextInputAction.go,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_identifierValid && !_busy) _send(resend: false);
              },
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                letterSpacing: 1.2,
              ),
              decoration: _webInputDecoration('Mobile number'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _webError(String message) {
    return Container(
      key: const Key('login_error'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xCC3A0B16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MocoColors.danger.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF8A9A),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFFFD5DB), fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- native

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
