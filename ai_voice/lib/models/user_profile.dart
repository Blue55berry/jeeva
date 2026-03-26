class UserProfile {
  final String name;
  final String email;
  final String? imagePath;

  UserProfile({
    required this.name,
    required this.email,
    this.imagePath,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'imagePath': imagePath,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      name: map['name'] as String? ?? 'Admin User',
      email: map['email'] as String? ?? 'admin@intercept.ai',
      imagePath: map['imagePath'] as String?,
    );
  }

  UserProfile copyWith({String? name, String? email, String? imagePath}) {
    return UserProfile(
      name: name ?? this.name,
      email: email ?? this.email,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}
