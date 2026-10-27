import 'package:simple_live_core/src/common/quickjs_runtime_host.dart';
import 'package:test/test.dart';

void main() {
  test('bootstraps once and reuses the same runtime', () {
    final host = QuickJsRuntimeHost(
      name: 'test',
      bootstrap: 'function add(a, b) { return a + b; }',
      idleTimeout: const Duration(minutes: 1),
    );

    expect(host.run((runtime) => runtime.eval('add(1, 2)')), 3);
    expect(host.run((runtime) => runtime.eval('add(3, 4)')), 7);
    expect(host.bootstrapCount, 1);

    host.dispose();
    expect(host.isAlive, isFalse);
  });
}
