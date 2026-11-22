import Foundation
import Network
import Testing
import dnssd
@testable import ConnectOnionKit

@Test(arguments: [
    (DeviceLinkError.expired, DeviceLinkFailure.expired),
    (.reused, .expired),
    (.wrongCode, .wrongCode),
    (.malformed, .other),
    (.cancelled, .cancelledOnOtherDevice),
    (.tampered, .other),
    (.addressMismatch, .other)
])
func linkErrorsBecomeNamedFailures(error: DeviceLinkError, failure: DeviceLinkFailure) {
    #expect(DeviceLinkFailure(error) == failure)
}

@Test func deniedLocalNetworkAccessIsNamed() {
    #expect(DeviceLinkFailure(NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))) == .localNetworkDenied)
}

@Test(arguments: [
    NWError.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)),
    .posix(.ETIMEDOUT),
    .posix(.ECONNREFUSED),
    .posix(.ENETUNREACH),
    .posix(.EHOSTUNREACH)
])
func unreachablePeersMeanNotOnTheSameNetwork(error: NWError) {
    #expect(DeviceLinkFailure(error) == .notOnSameNetwork)
}

@Test func anyOtherErrorIsTheGenericFailure() {
    #expect(DeviceLinkFailure(CocoaError(.fileWriteUnknown)) == .other)
}

@Test func everyFailureHasItsOwnTitleAndSaysWhatToDoNext() {
    let failures: [DeviceLinkFailure] = [
        .expired, .notOnSameNetwork, .wrongCode, .mistypedCode, .cancelledOnOtherDevice, .localNetworkDenied, .couldNotSave, .other
    ]

    #expect(Set(failures.map(\.title)).count == failures.count)
    #expect(failures.allSatisfy { !$0.nextStep.isEmpty })
    #expect(DeviceLinkFailure.localNetworkDenied.nextStep.contains("Local Network"))
    // A code turned away before connecting is still good on the other device; one the giver rejected is used up.
    #expect(DeviceLinkFailure.mistypedCode.nextStep.contains("enter it again"))
    #expect(DeviceLinkFailure.wrongCode.nextStep.contains("Make a new code"))
}
