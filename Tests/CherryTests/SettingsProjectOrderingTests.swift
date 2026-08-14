import Testing
@testable import Cherry

@Test func settingsProjectsAreOrderedByName() {
    let projects = [
        CherryProject(root: "/work/zeta"),
        CherryProject(root: "/work/Alpha"),
        CherryProject(root: "/work/beta"),
    ]

    #expect(SettingsProjectOrdering.byName(projects).map(\.name) == [
        "Alpha",
        "beta",
        "zeta",
    ])
}

@Test func settingsProjectsWithMatchingNamesUseTheirPathsAsATieBreaker() {
    let projects = [
        CherryProject(root: "/work/zeta/cloud"),
        CherryProject(root: "/work/alpha/cloud"),
    ]

    #expect(SettingsProjectOrdering.byName(projects).map(\.root) == [
        "/work/alpha/cloud",
        "/work/zeta/cloud",
    ])
}
