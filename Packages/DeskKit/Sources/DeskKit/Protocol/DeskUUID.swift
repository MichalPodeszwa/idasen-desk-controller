public enum DeskUUID {
  static let suffix = "-338A-1024-8A49-009C0215F78A"

  public static let controlService = "99FA0001" + suffix
  public static let control = "99FA0002" + suffix
  public static let error = "99FA0003" + suffix
  public static let dpgService = "99FA0010" + suffix
  public static let dpg = "99FA0011" + suffix
  public static let referenceOutputService = "99FA0020" + suffix
  public static let referenceOutput = "99FA0021" + suffix
  public static let referenceInputService = "99FA0030" + suffix
  public static let referenceInput = "99FA0031" + suffix

  public static let advertisedService = controlService
}
