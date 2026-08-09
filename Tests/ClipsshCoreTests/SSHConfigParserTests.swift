import Testing
@testable import ClipsshCore

@Test func parsesSimpleHostEntries() {
    let text = """
    Host alpha
        HostName alpha.example.com
    Host beta
        HostName beta.example.com
    """
    #expect(SSHConfigParser.parse(text).hosts == ["alpha", "beta"])
}

@Test func parsesMultipleNamesOnOneHostLine() {
    #expect(SSHConfigParser.parse("Host alpha beta gamma").hosts == ["alpha", "beta", "gamma"])
}

@Test func excludesWildcardPatterns() {
    let text = """
    Host *
        ForwardAgent yes
    Host web?
        User admin
    Host !excluded
        User admin
    Host alpha
        User admin
    """
    // Wildcards and negations are not connectable host names.
    #expect(SSHConfigParser.parse(text).hosts == ["alpha"])
}

@Test func ignoresCommentsAndIndentationAndCase() {
    let text = """
    # Host commented
       host alpha
    	HOST beta
    """
    #expect(SSHConfigParser.parse(text).hosts == ["alpha", "beta"])
}

@Test func stripsTrailingCommentOnHostLine() {
    #expect(SSHConfigParser.parse("Host alpha # my box").hosts == ["alpha"])
}

@Test func stripsTrailingCommentAfterMultipleNames() {
    #expect(SSHConfigParser.parse("Host alpha beta # trailing").hosts == ["alpha", "beta"])
}

@Test func hostLineWithOnlyACommentYieldsNoHosts() {
    #expect(SSHConfigParser.parse("Host # comment").hosts == [])
}

@Test func removesDuplicatesKeepingFirstOrder() {
    #expect(SSHConfigParser.parse("Host alpha\nHost beta\nHost alpha").hosts == ["alpha", "beta"])
}

@Test func flagsIncludeAsUnsupported() {
    let result = SSHConfigParser.parse("Include ~/.ssh/config.d/*\nHost alpha")
    #expect(result.hasUnsupportedInclude)
    #expect(result.hosts == ["alpha"])
}

@Test func reportsNoIncludeWhenAbsent() {
    #expect(SSHConfigParser.parse("Host alpha").hasUnsupportedInclude == false)
}

@Test func stripsCarriageReturnsFromCRLFLineEndings() {
    #expect(SSHConfigParser.parse("Host alpha\r\nHost beta\r\n").hosts == ["alpha", "beta"])
}

@Test func handlesEmptyInput() {
    #expect(SSHConfigParser.parse("") == SSHConfigParser.Result(hosts: [], hasUnsupportedInclude: false))
}
