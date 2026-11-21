import ElenathCore

/// `Subject` is also the name of Combine's publisher protocol, which SwiftUI makes visible in every file
/// that imports it. Declaring the name in the app module makes `Subject` mean Elenath's model type in every
/// app file, whatever else is imported.
typealias Subject = ElenathCore.Subject
