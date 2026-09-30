import Foundation

struct RepositoryActionPreview: Identifiable {
    let id = UUID()
    let repositoryName: String
    let repositoryURL: URL
    var plan: RepositoryActionPlan?
    var status = "Ready"
    var error: String?
    var completed = false
}

struct RepositoryActionSession: Identifiable {
    let id = UUID()
    let actionID: String
    var previews: [RepositoryActionPreview] = []
    var isPreparing = true
    var isRunning = false
    var finished = false
}
