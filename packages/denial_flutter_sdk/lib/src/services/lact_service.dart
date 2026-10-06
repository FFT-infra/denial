import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lact_client.dart';

export 'lact_client.dart';

final lactServiceProvider = Provider<LactService>((ref) => LactService());
