import UIKit


public indirect enum BrandColors {
  static public let primary: UIColor = #colorLiteral(red: 1, green: 0.666666666667, blue: 0.733333333333, alpha: 1)
  public indirect enum Nested {
    static public let accent: UIColor = #colorLiteral(red: 0.529411764706, green: 0.807843137255, blue: 0.921568627451, alpha: 1)
  }
  public indirect enum Accessible {
    static public let text: UIColor = #colorLiteral(red: 0.133333333333, green: 0.133333333333, blue: 0.133333333333, alpha: 1)
    static public let background: UIColor = #colorLiteral(red: 0.996078431373, green: 0.996078431373, blue: 0.996078431373, alpha: 1)
  }
}
