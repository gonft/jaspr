import 'package:jaspr/server.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/serverpod_auth_idp_server.dart';
import 'package:serverpod_auth_server/serverpod_auth_server.dart' as auth;

import 'main.server.options.dart';
import 'src/generated/endpoints.dart';
import 'src/generated/protocol.dart';
import 'src/routes/root.dart';

// This is the starting point of your Serverpod server. In most cases, you will
// only need to make additions to this file if you add future calls,  are
// configuring Relic (Serverpod's web-server), or need custom setup work.

Serverpod? _runningPod;

void main(List<String> args) async {
  if (_runningPod case final pod?) {
    await pod.shutdown(exitProcess: false);
  }

  // Initialize Serverpod and connect it with your generated code.
  final pod = Serverpod(args, Protocol(), Endpoints());
  _runningPod = pod;

  pod.initializeAuthServices(
    tokenManagerBuilders: [
      JwtConfig(
        refreshTokenHashPepper: pod.getPassword('jwtRefreshTokenHashPepper')!,
        algorithm: JwtAlgorithm.hmacSha512(
          SecretKey(pod.getPassword('jwtHmacSha512PrivateKey')!),
        ),
      ),
    ],
    identityProviderBuilders: [
      GoogleIdpConfig(
        clientSecret: GoogleClientSecret.fromJsonString(
          pod.getPassword('googleClientSecret')!,
        ),
      ),
    ],
  );

  Jaspr.initializeApp(options: defaultServerOptions, useIsolates: false);

  // If you are using any future calls, they need to be registered here.
  // pod.registerFutureCall(ExampleFutureCall(), 'exampleFutureCall');

  final router = pod.webServer.router;
  router.injectAt('/googlesignin', auth.RouteGoogleSignIn());
  router.injectAt('/**', RootRoute());

  // Start the server.
  await pod.start();
}
