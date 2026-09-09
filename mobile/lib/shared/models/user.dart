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
  });

  final bool isOnline;
  final String kycStatus;
  final int earningsBalance;
  final double rating;
  final int totalCalls;

  factory ListenerState.fromJson(Map<String, dynamic> json) {
    return ListenerState(
      isOnline: json['isOnline'] as bool? ?? false,
      kycStatus: json['kycStatus'] as String? ?? 'unsubmitted',
      earningsBalance: (json['earningsBalance'] as num?)?.toInt() ?? 0,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
    );
  }

  /// Only an approved listener may go online or appear in discovery.
  bool get isApproved => kycStatus == 'approved';
  bool get isAwaitingReview => kycStatus == 'pending';
  bool get wasRejected => kycStatus == 'rejected';

  @override
  bool operator ==(Object other) =>
      other is ListenerState &&
      other.isOnline == isOnline &&
      other.kycStatus == kycStatus &&
      other.earningsBalance == earningsBalance &&
      other.rating == rating &&
      other.totalCalls == totalCalls;

  @override
  int get hashCode =>
      Object.hash(isOnline, kycStatus, earningsBalance, rating, totalCalls);
}

/// The signed-in user, as returned by `GET /api/users/me`.
///
/// `coinBalance` is displayed but never trusted for a decision — the server
/// re-checks the balance on every call that spends it.
class MocoUser {
  const MocoUser({
    required this.id,
    required this.phone,
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
  final String phone;
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
    this.displayName,
    this.role = 'user',
    this.language = 'en',
    this.profileComplete = false,
  });

  final int id;
  final String phone;
  final String? displayName;
  final String role;
  final String language;
  final bool profileComplete;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['id'] as num).toInt(),
      phone: json['phone'] as String? ?? '',
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
