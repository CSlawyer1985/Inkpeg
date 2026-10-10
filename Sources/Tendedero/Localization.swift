import Foundation
import InkpegCore

var appLocalizer = Localizer()
func L(_ key: MessageKey) -> String { appLocalizer.string(key) }
