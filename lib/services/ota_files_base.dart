abstract class OtaFileWriter {
  Future<void> add(List<int> bytes);
  Future<String> commit();
  Future<void> discard();
}

abstract class OtaFileStorage {
  Future<OtaFileWriter> create(int buildNumber);
}
