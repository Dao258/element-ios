// 
// Copyright 2021 New Vector Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

protocol AuthenticationServiceDelegate: AnyObject {
    /// The authentication service received an SSO login token via a deep link.
    /// This only occurs when SSOAuthenticationPresenter uses an SFSafariViewController.
    /// - Parameters:
    ///   - service: The authentication service.
    ///   - ssoLoginToken: The login token provided when SSO succeeded.
    ///   - transactionID: The transaction ID generated during SSO page presentation.
    /// - Returns: `true` if the SSO login can be continued.
    func authenticationService(_ service: AuthenticationService, didReceive ssoLoginToken: String, with transactionID: String) -> Bool
}

class AuthenticationService: NSObject {
    
    /// The shared service object.
    static let shared = AuthenticationService()
    
    // MARK: - Properties
    
    // MARK: Private
    
    /// The rest client used to make authentication requests.
    private var client: AuthenticationRestClient
    /// The object used to create a new `MXSession` when authentication has completed.
    private var sessionCreator = SessionCreator()
    
    // MARK: Public
    
    /// The current state of the authentication flow.
    private(set) var state: AuthenticationState
    /// The current login wizard or `nil` if `startFlow` hasn't been called.
    private(set) var loginWizard: LoginWizard?
    /// The current registration wizard or `nil` if `startFlow` hasn't been called for `.registration`.
    private(set) var registrationWizard: RegistrationWizard?
    
    /// The authentication service's delegate.
    weak var delegate: AuthenticationServiceDelegate?
    
    // MARK: - Setup
    
    override init() {
        guard let homeserverURL = URL(string: BuildSettings.serverConfigDefaultHomeserverUrlString) else {
            MXLog.failure("[AuthenticationService]: Failed to create URL from default homeserver URL string.")
            fatalError("Invalid default homeserver URL string.")
        }
        
        state = AuthenticationState(flow: .login, homeserverAddress: BuildSettings.serverConfigDefaultHomeserverUrlString)
        client = MXRestClient(homeServer: homeserverURL, unrecognizedCertificateHandler: nil)
        
        super.init()
    }
    
    // MARK: - Public
    
    /// Whether authentication is needed by checking for any accounts.
    /// - Returns: `true` there are no accounts or if there is an inactive account that has had a soft logout.
    var needsAuthentication: Bool {
        MXKAccountManager.shared().accounts.isEmpty || softLogoutCredentials != nil
    }
    
    /// Credentials to be used when authenticating after soft logout, otherwise `nil`.
    var softLogoutCredentials: MXCredentials? {
        guard MXKAccountManager.shared().activeAccounts.isEmpty else { return nil }
        for account in MXKAccountManager.shared().accounts {
            if account.isSoftLogout {
                return account.mxCredentials
            }
        }
        
        return nil
    }
    
    /// Get the last authenticated [Session], if there is an active session.
    /// - Returns: The last active session if any, or `nil`
    var lastAuthenticatedSession: MXSession? {
        MXKAccountManager.shared().activeAccounts?.first?.mxSession
    }
    
    func startFlow(_ flow: AuthenticationFlow, for homeserverAddress: String) async throws {
        var (client, homeserver) = try await loginFlow(for: homeserverAddress)
        
        let loginWizard = LoginWizard(client: client)
        self.loginWizard = loginWizard
        
        if flow == .register {
            do {
                let registrationWizard = RegistrationWizard(client: client)
                homeserver.registrationFlow = try await registrationWizard.registrationFlow()
                self.registrationWizard = registrationWizard
            } catch {
                guard homeserver.preferredLoginMode.hasSSO, error as? RegistrationError == .registrationDisabled else {
                    throw error
                }
                // Continue without throwing when registration is disabled but SSO is available.
            }
        }
        
        // The state and client are set after trying the registration flow to
        // ensure the existing state isn't wiped out when an error occurs.
        self.state = AuthenticationState(flow: flow, homeserver: homeserver)
        self.client = client
    }
    
    /// Get the sign in or sign up fallback URL
    func fallbackURL(for flow: AuthenticationFlow) -> URL {
        switch flow {
        case .login:
            return client.loginFallbackURL
        case .register:
            return client.registerFallbackURL
        }
    }
    
    /// True when login and password has been sent with success to the homeserver
    var isRegistrationStarted: Bool {
        registrationWizard?.isRegistrationStarted ?? false
    }
    
    /// Reset the service to a fresh state.
    func reset() {
        loginWizard = nil
        registrationWizard = nil

        // The previously used homeserver is re-used as `startFlow` will be called again a replace it anyway.
        let address = state.homeserver.addressFromUser ?? state.homeserver.address
        self.state = AuthenticationState(flow: .login, homeserverAddress: address)
    }
    
    /// Continues an SSO flow when completion comes via a deep link.
    /// - Parameters:
    ///   - token: The login token provided when SSO succeeded.
    ///   - transactionID: The transaction ID generated during SSO page presentation.
    /// - Returns: `true` if the SSO login can be continued.
    func continueSSOLogin(with token: String, and transactionID: String) -> Bool {
        delegate?.authenticationService(self, didReceive: token, with: transactionID) ?? false
    }
    
//    /// Perform a well-known request, using the domain from the matrixId
//    func getWellKnownData(matrixId: String,
//                          homeServerConnectionConfig: HomeServerConnectionConfig?) async -> WellknownResult {
//
//    }
//
//    /// Authenticate with a matrixId and a password
//    /// Usually call this after a successful call to getWellKnownData()
//    /// - Parameter homeServerConnectionConfig the information about the homeserver and other configuration
//    /// - Parameter matrixId the matrixId of the user
//    /// - Parameter password the password of the account
//    /// - Parameter initialDeviceName the initial device name
//    /// - Parameter deviceId the device id, optional. If not provided or null, the server will generate one.
//    func directAuthentication(homeServerConnectionConfig: HomeServerConnectionConfig,
//                              matrixId: String,
//                              password: String,
//                              initialDeviceName: String,
//                              deviceId: String? = nil) async -> MXSession {
//        
//    }
    
    // MARK: - Private
    
    /// Query the supported login flows for the supplied homeserver.
    /// This is the first method to call to be able to get a wizard to login or to create an account
    /// - Parameter homeserverAddress: The homeserver string entered by the user.
    /// - Returns: A tuple containing the REST client for the server along with the homeserver state containing the login flows.
    private func loginFlow(for homeserverAddress: String) async throws -> (AuthenticationRestClient, AuthenticationState.Homeserver) {
        let homeserverAddress = HomeserverAddress.sanitized(homeserverAddress)
        
        guard var homeserverURL = URL(string: homeserverAddress) else {
            MXLog.error("[AuthenticationService] Unable to create a URL from the supplied homeserver address when calling loginFlow.")
            throw AuthenticationError.invalidHomeserver
        }
        
        if let wellKnown = try? await wellKnown(for: homeserverURL),
           let baseURL = URL(string: wellKnown.homeServer.baseUrl) {
            homeserverURL = baseURL
        }
        
        #warning("Add an unrecognized certificate handler.")
        let client = MXRestClient(homeServer: homeserverURL, unrecognizedCertificateHandler: nil)
        
        let loginFlow = try await getLoginFlowResult(client: client)
        
        let homeserver = AuthenticationState.Homeserver(address: loginFlow.homeserverAddress,
                                                        addressFromUser: homeserverAddress,
                                                        preferredLoginMode: loginFlow.loginMode)
        return (client, homeserver)
    }
    
    /// Request the supported login flows for the corresponding session.
    /// This method is used to get the flows for a server after a soft-logout.
    /// - Parameter session: The MXSession where a soft-logout has occurred.
    private func loginFlow(for session: MXSession) async throws -> (AuthenticationRestClient, AuthenticationState.Homeserver) {
        guard let client = session.matrixRestClient else {
            MXLog.error("[AuthenticationService] loginFlow called on a session that doesn't have a matrixRestClient.")
            throw AuthenticationError.missingMXRestClient
        }
        
        let loginFlow = try await getLoginFlowResult(client: session.matrixRestClient)
        
        let homeserver = AuthenticationState.Homeserver(address: loginFlow.homeserverAddress,
                                                        preferredLoginMode: loginFlow.loginMode)
        return (client, homeserver)
    }
    
    private func getLoginFlowResult(client: MXRestClient) async throws -> LoginFlowResult {
        // Get the login flow
        let loginFlowResponse = try await client.getLoginSession()
        
        let identityProviders = loginFlowResponse.flows?.compactMap { $0 as? MXLoginSSOFlow }.first?.identityProviders ?? []
        return LoginFlowResult(supportedLoginTypes: loginFlowResponse.flows?.compactMap { $0 } ?? [],
                               ssoIdentityProviders: identityProviders.sorted { $0.name < $1.name }.map { $0.ssoIdentityProvider },
                               homeserverAddress: client.homeserver)
    }
    
    /// Perform a well-known request on the specified homeserver URL.
    private func wellKnown(for homeserverURL: URL) async throws -> MXWellKnown {
        let wellKnownClient = MXRestClient(homeServer: homeserverURL, unrecognizedCertificateHandler: nil)
        
        // The .well-known/matrix/client API is often just a static file returned with no content type.
        // Make our HTTP client compatible with this behaviour
        wellKnownClient.acceptableContentTypes = nil
        
        return try await wellKnownClient.wellKnown()
    }
}

extension MXLoginSSOIdentityProvider {
    var ssoIdentityProvider: SSOIdentityProvider {
        SSOIdentityProvider(id: identifier, name: name, brand: brand, iconURL: icon)
    }
}
