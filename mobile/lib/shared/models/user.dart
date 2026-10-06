/// Listener capability carried on the signed-in user.
///
/// Phase 1 models listener status as state on the user rather than a separate
/// navigation shell, so a later phase can add listener surfaces without
/// restructuring routing.
class ListenerState {
  const ListenerState({
    this.isOnline = false,
    this.kycStatus = 'unsubmitted',
    this.earningsBalance = 0,
    this.rating = 0,
    this.totalCalls = 0,
    this.photoCount = 0,
    this.minPhotos = 3,
    this.maxPhotos = 6,
    List<String>? blockers,
    this.kycSubmittedAt,
    this.kycRejectionReason,
  }) // A private field cannot be a named parameter, hence the initializer.
    // ignore: prefer_initializing_formals
    : _blockers = blockers;

  final bool isOnline;
  final String kycStatus;
  final int earningsBalance;
  final double rating;
  final int totalCalls;
  final int photoCount;
  final int minPhotos;
  final int maxPhotos;

  /// What still stands between this listener and being active, computed BY
  /// THE SERVER ('photos', 'kyc'). Empty means eligible. The app displays
  /// this rather than re-deriving the rule, so the two can never disagree.
  /// When the server didn't send any (an older server), approval decides.
  final List<String>? _blockers;
  List<String> get blockers =>
      _blockers ?? (kycStatus == 'approved' ? const [] : const ['kyc']);
  final DateTime? kycSubmittedAt;

  /// The reviewer's reason, present only when [kycStatus] is 'rejected'.
  final String? kycRejectionReason;

  factory ListenerState.fromJson(Map<String, dynamic> json) {
    final blockers = json['blockers'];
    return ListenerState(
      isOnline: json['isOnline'] as bool? ?? false,
      kycStatus: json['kycStatus'] as String? ?? 'unsubmitted',
      earningsBalance: (json['earningsBalance'] as num?)?.toInt() ?? 0,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
      photoCount: (json['photoCount'] as num?)?.toInt() ?? 0,
      minPhotos: (json['minPhotos'] as num?)?.toInt() ?? 3,
      maxPhotos: (json['maxPhotos'] as num?)?.toInt() ?? 6,
      blockers: blockers is List
          ? blockers.map((b) => b.toString()).toList(growable: false)
          : null,
      kycSubmittedAt: DateTime.tryParse(
        json['kycSubmittedAt'] as String? ?? '',
      ),
      kycRejectionReason: json['kycRejectionReason'] as String?,
    );
  }

  bool get isApproved => kycStatus == 'approved';
  bool get isAwaitingReview => kycStatus == 'pending';
  bool get wasRejected => kycStatus == 'rejected';
  bool get hasNotSubmitted => kycStatus == 'unsubmitted';

  /// Active = approved KYC AND the minimum photos, per the server.
  bool get isEligible => blockers.isEmpty;
  bool get needsPhotos => photoCount < minPhotos;

  /// KYC can be (re)submitted from draft or after a rejection — the same
  /// states the backend accepts a submission from.
  bool get canSubmitKyc => hasNotSubmitted || wasRejected;

  @override
  bool operator ==(Object other) =>
      other is ListenerState &&
      other.isOnline == isOnline &&
      other.kycStatus == kycStatus &&
      other.earningsBalance == earningsBalance &&
      other.rating == rating &&
      other.totalCalls == totalCalls &&
      other.photoCount == photoCount &&
      other.blockers.join(',') == blockers.join(',') &&
      other.kycRejectionReason == kycRejectionReason;

  @override
  int get hashCode => Object.hash(
    isOnline,
    kycStatus,
    earningsBalance,
    rating,
    totalCalls,
    photoCount,
    blockers.join(','),
    kycRejectionReason,
  );
}

/// Why a listener cannot go online, in plain words, derived from the
/// server's [ListenerState.blockers] and KYC status. Empty when eligible.
List<String> listenerEligibilityReasons(ListenerState l) {
  final reasons = <String>[];
  if (l.needsPhotos) {
    final missing = l.minPhotos - l.photoCount;
    reasons.add(
      'Add $missing more profile photo${missing == 1 ? '' : 's'} '
      '(${l.photoCount} of ${l.minPhotos} required)',
    );
  }
  if (!l.isApproved) {
    reasons.add(switch (l.kycStatus) {
      'pending' => 'Verification is under review',
      'rejected' => 'Verification was rejected — update and resubmit',
      _ => 'Submit identity verification',
    });
  }
  return reasons;
}

/// The signed-in user, as returned by `GET /api/users/me`.
///
/// `coinBalance` is displayed but never trusted for a decision — the server
/// re-checks the balance on every call that spends it.
class MocoUser {
  const MocoUser({
    required this.id,
    required this.phone,
    this.email,
    this.displayName,
    this.avatarUrl,
    this.language = 'en',
    this.gender,
    this.role = 'user',
    this.coinBalance = 0,
    this.freeTrialAvailable = false,
    this.listener,
  });

  final int id;

  /// Empty for an account that signed up by email and has no phone yet.
  final String phone;

  /// The verified sign-in email, when the account has one.
  final String? email;
  final String? displayName;
  final String? avatarUrl;
  final String language;
  final String? gender;
  final String role;
  final int coinBalance;
  final bool freeTrialAvailable;
  final ListenerState? listener;

  factory MocoUser.fromJson(Map<String, dynamic> json) {
    final listenerJson = json['listener'];
    return MocoUser(
      id: (json['id'] as num).toInt(),
      phone: json['phone'] as String? ?? '',
      email: json['email'] as String?,
      displayName: json['displayName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      language: json['language'] as String? ?? 'en',
      gender: json['gender'] as String?,
      role: json['role'] as String? ?? 'user',
      coinBalance: (json['coinBalance'] as num?)?.toInt() ?? 0,
      freeTrialAvailable: json['freeTrialAvailable'] as bool? ?? false,
      listener: listenerJson is Map
          ? ListenerState.fromJson(Map<String, dynamic>.from(listenerJson))
          : null,
    );
  }

  /// Profile completion gate for routing.
  ///
  /// The backend's own definition on OTP verify is `Boolean(display_name)`, so
  /// this mirrors it exactly rather than inventing a stricter rule.
  bool get isProfileComplete =>
      displayName != null && displayName!.trim().isNotEmpty;

  bool get canBeListener => role == 'listener' || role == 'both';

  /// How the account is identified to its owner: the phone number, or the
  /// email for an account that signed up by email.
  String get contactLabel => phone.isNotEmpty ? phone : (email ?? '');

  MocoUser copyWith({
    String? displayName,
    String? avatarUrl,
    String? language,
    String? gender,
    String? role,
    int? coinBalance,
    bool? freeTrialAvailable,
    ListenerState? listener,
  }) {
    return MocoUser(
      id: id,
      phone: phone,
      email: email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      language: language ?? this.language,
      gender: gender ?? this.gender,
      role: role ?? this.role,
      coinBalance: coinBalance ?? this.coinBalance,
      freeTrialAvailable: freeTrialAvailable ?? this.freeTrialAvailable,
      listener: listener ?? this.listener,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MocoUser &&
      other.id == id &&
      other.phone == phone &&
      other.email == email &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      other.language == language &&
      other.gender == gender &&
      other.role == role &&
      other.coinBalance == coinBalance &&
      other.freeTrialAvailable == freeTrialAvailable &&
      other.listener == listener;

  @override
  int get hashCode => Object.hash(
    id,
    phone,
    email,
    displayName,
    avatarUrl,
    language,
    gender,
    role,
    coinBalance,
    freeTrialAvailable,
    listener,
  );
}

/// The lighter user shape returned by `POST /api/auth/otp/verify`.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.phone,
    this.email,
    this.displayName,
    this.role = 'user',
    this.language = 'en',
    this.profileComplete = false,
  });

  final int id;
  final String phone;
  final String? email;
  final String? displayName;
  final String role;
  final String language;
  final bool profileComplete;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['id'] as num).toInt(),
      phone: json['phone'] as String? ?? '',
      email: json['email'] as String?,
      displayName: json['displayName'] as String?,
      role: json['role'] as String? ?? 'user',
      language: json['language'] as String? ?? 'en',
      profileComplete: json['profileComplete'] as bool? ?? false,
    );
  }
}

/// Result of a successful OTP verification.
class AuthSession {
  const AuthSession({
    required this.token,
    this.isNew = false,
    required this.user,
  });

  final String token;
  final bool isNew;
  final AuthUser user;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      token: json['token'] as String,
      isNew: json['isNew'] as bool? ?? false,
      user: AuthUser.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
    );
  }
}
