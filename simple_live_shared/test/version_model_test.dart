import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_shared/models/version_model.dart';

void main() {
  test('VersionModel JSON 往返保持字段', () {
    final model = VersionModel(
      version: '1.0.0',
      versionNum: 100,
      versionDesc: '描述',
      downloadUrl: 'https://example.com/app.apk',
    );

    final parsed = VersionModel.fromJson(model.toJson());
    expect(parsed.version, '1.0.0');
    expect(parsed.versionNum, 100);
    expect(parsed.versionDesc, '描述');
    expect(parsed.downloadUrl, 'https://example.com/app.apk');
  });
}
