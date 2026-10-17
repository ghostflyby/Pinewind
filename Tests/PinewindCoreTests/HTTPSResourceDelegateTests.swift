// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import PinewindCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Resource authentication delegation", .timeLimit(.minutes(1)))
struct HTTPSResourceDelegateTests {
  @Test func forwardsSessionAndTaskChallengesWithOriginalContext() async throws {
    let delegate = AuthenticationRecorder()
    let original = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let transport = URLSession(configuration: .ephemeral)
    defer {
      original.invalidateAndCancel()
      transport.invalidateAndCancel()
    }
    let forwarding = HTTPSResourceDelegate(session: original)
    let task = transport.dataTask(with: URL(string: "https://resource.test/auth")!)
    defer { task.cancel() }
    let challenge = makeChallenge()
    let sessionResult: (URLSession.AuthChallengeDisposition, URLCredential?) =
      await withCheckedContinuation { continuation in
        forwarding.urlSession(transport, didReceive: challenge) {
          continuation.resume(returning: ($0, $1))
        }
      }
    #expect(sessionResult.0 == .rejectProtectionSpace)
    #expect(sessionResult.1 == nil)
    let taskResult: (URLSession.AuthChallengeDisposition, URLCredential?) =
      await withCheckedContinuation { continuation in
        forwarding.urlSession(transport, task: task, didReceive: challenge) {
          continuation.resume(returning: ($0, $1))
        }
      }
    #expect(taskResult.0 == .useCredential)
    #expect(taskResult.1 === delegate.credential)
    let seen = delegate.observations()
    #expect(seen.sessions == [ObjectIdentifier(original), ObjectIdentifier(original)])
    #expect(seen.tasks == [ObjectIdentifier(task)])
    #expect(seen.challenges == [ObjectIdentifier(challenge), ObjectIdentifier(challenge)])
  }

  @Test(arguments: FallbackDelegate.allCases)
  func missingAuthenticationHandlersUseDefaultHandling(_ kind: FallbackDelegate) async throws {
    let delegate: (any URLSessionDelegate)? =
      switch kind {
      case .none: nil
      case .session: EmptySessionDelegate()
      case .task: EmptyTaskDelegate()
      }
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let forwarding = HTTPSResourceDelegate(session: session)
    let task = session.dataTask(with: URL(string: "https://resource.test/auth")!)
    defer { task.cancel() }
    let challenge = makeChallenge()
    let sessionResult: (URLSession.AuthChallengeDisposition, URLCredential?) =
      await withCheckedContinuation { continuation in
        forwarding.urlSession(session, didReceive: challenge) {
          continuation.resume(returning: ($0, $1))
        }
      }
    #expect(sessionResult.0 == .performDefaultHandling)
    #expect(sessionResult.1 == nil)
    let taskResult: (URLSession.AuthChallengeDisposition, URLCredential?) =
      await withCheckedContinuation { continuation in
        forwarding.urlSession(session, task: task, didReceive: challenge) {
          continuation.resume(returning: ($0, $1))
        }
      }
    #expect(taskResult.0 == .performDefaultHandling)
    #expect(taskResult.1 == nil)
  }

  enum FallbackDelegate: CaseIterable, Sendable { case none, session, task }
}

private final class AuthenticationRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let credential = URLCredential(user: "user", password: "secret", persistence: .none)
  private let lock = NSLock()
  private var sessions: [ObjectIdentifier] = []
  private var tasks: [ObjectIdentifier] = []
  private var challenges: [ObjectIdentifier] = []
  func observations() -> (
    sessions: [ObjectIdentifier], tasks: [ObjectIdentifier], challenges: [ObjectIdentifier]
  ) {
    lock.withLock { (sessions, tasks, challenges) }
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    lock.withLock {
      sessions.append(ObjectIdentifier(session))
      challenges.append(ObjectIdentifier(challenge))
    }
    completionHandler(.rejectProtectionSpace, nil)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    lock.withLock {
      sessions.append(ObjectIdentifier(session))
      tasks.append(ObjectIdentifier(task))
      challenges.append(ObjectIdentifier(challenge))
    }
    completionHandler(.useCredential, credential)
  }
}
private final class EmptySessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}
private final class EmptyTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {}

private func makeChallenge() -> URLAuthenticationChallenge {
  URLAuthenticationChallenge(
    protectionSpace: URLProtectionSpace(
      host: "resource.test", port: 443, protocol: "https", realm: "resource",
      authenticationMethod: NSURLAuthenticationMethodHTTPBasic),
    proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
    sender: ChallengeSender())
}
private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
