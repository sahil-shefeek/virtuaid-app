import 'package:dio/dio.dart';
import '../models/user_model.dart';
import '../models/auth_model.dart';
import 'token_service.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  final Dio _dio;
  final TokenService _tokenService;
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email', 'profile']);

  AuthService(this._dio, this._tokenService);

  // Login user - no longer stores access token
  Future<AuthModel> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        'auth/app/login/',
        data: {'username': username, 'password': password},
      );

      final accessToken = response.data['access'];
      final refreshToken = response.data['refresh'];

      // Only store the refresh token persistently
      await _tokenService.saveRefreshToken(refreshToken);

      final user = await _fetchUserInfo(accessToken);

      return AuthModel(accessToken: accessToken, user: user);
    } catch (e) {
      throw _handleError(e, 'Login failed');
    }
  }

  // Register new user
  Future<AuthModel> register({
    required String username,
    required String email,
    required String password1,
    required String password2,
    required String name,
  }) async {
    try {
      final response = await _dio.post(
        'auth/app/register/',
        data: {
          'username': username,
          'email': email,
          'password1': password1,
          'password2': password2,
          'name': name,
        },
      );

      final accessToken = response.data['access'];
      final refreshToken = response.data['refresh'];

      // Only store the refresh token persistently
      await _tokenService.saveRefreshToken(refreshToken);

      final user = await _fetchUserInfo(accessToken);

      return AuthModel(accessToken: accessToken, user: user);
    } catch (e) {
      throw _handleError(e, 'Registration failed');
    }
  }

  // Google Sign-In method
  Future<AuthModel> googleLogin() async {
    try {
      // Start the Google Sign-In process
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        throw Exception('Google Sign-In was cancelled');
      }

      // Get the authentication details
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Get ID token and access token
      final String? accessToken = googleAuth.accessToken;

      if (accessToken == null) {
        throw Exception('Could not get Google access token');
      }

      // Send the access token to your backend
      final response = await _dio.post(
        '/auth/google/callback/',
        data: {'access_token': accessToken},
      );

      final backendAccessToken = response.data['access'];
      final refreshToken = response.data['refresh'];

      // Store the refresh token
      await _tokenService.saveRefreshToken(refreshToken);

      // Fetch user info using the token from your backend
      final user = await _fetchUserInfo(backendAccessToken);

      return AuthModel(accessToken: backendAccessToken, user: user);
    } catch (e) {
      throw _handleError(e, 'Google login failed');
    }
  }

  // Logout user - takes current access token as parameter
  Future<void> logout(String? accessToken) async {
    try {
      final refreshToken = await _tokenService.getRefreshToken();
      if (accessToken != null) {
        await _dio.post(
          '/auth/app/logout/',
          data: {'refresh': refreshToken},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        );
      }
    } catch (e) {
      // We still want to clear tokens even if the request fails
      print('Logout API call failed, but continuing to clear local tokens: $e');
    } finally {
      await _tokenService.clearTokens();
    }
  }

  // Refresh access token
  Future<String?> refreshToken() async {
    try {
      final refreshToken = await _tokenService.getRefreshToken();

      if (refreshToken == null) {
        throw Exception('No refresh token found');
      }

      final response = await _dio.post(
        'auth/app/token/refresh/',
        data: {'refresh': refreshToken},
      );

      // Return the new token but don't store it persistently
      return response.data['access'];
    } catch (e) {
      print('Token refresh failed: $e');
      // Clear refresh token if refresh fails
      await _tokenService.clearTokens();
      return null;
    }
  }

  // Verify current authentication status
  Future<AuthModel> checkAuthStatus(String? currentAccessToken) async {
    if (currentAccessToken == null) {
      // Try to refresh the token if there's a refresh token
      final newToken = await refreshToken();

      if (newToken == null) {
        return AuthModel.initial();
      }

      // If we got a new token, fetch user info
      final user = await _fetchUserInfo(newToken);
      return AuthModel(accessToken: newToken, user: user);
    }

    try {
      // Verify token validity by fetching user info
      final user = await _fetchUserInfo(currentAccessToken);
      return AuthModel(accessToken: currentAccessToken, user: user);
    } catch (e) {
      // If token is invalid, try refreshing
      final newToken = await refreshToken();

      if (newToken == null) {
        return AuthModel.initial();
      }

      final user = await _fetchUserInfo(newToken);
      return AuthModel(accessToken: newToken, user: user);
    }
  }

  // Helper to fetch user information
  Future<UserModel> _fetchUserInfo(String token) async {
    try {
      final response = await _dio.get(
        '/auth/app/user/',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );

      return UserModel.fromJson({
        ...response.data,
        'isAdmin': response.data['is_admin'] ?? false,
      });
    } catch (e) {
      throw _handleError(e, 'Failed to fetch user information');
    }
  }

  // Error handling helper
  Exception _handleError(dynamic error, String fallbackMessage) {
    if (error is DioException) {
      if (error.response != null) {
        final data = error.response?.data;
        if (data != null && data is Map) {
          // Extract error messages
          String errorMsg = '';
          data.forEach((key, value) {
            if (value is List) {
              errorMsg += '$key: ${value.join(', ')}\n';
            } else {
              errorMsg += '$key: $value\n';
            }
          });
          return Exception(errorMsg.trim());
        }
        return Exception(
          '${error.response?.statusCode}: ${error.response?.statusMessage}',
        );
      }
    }
    return Exception(fallbackMessage);
  }
}
