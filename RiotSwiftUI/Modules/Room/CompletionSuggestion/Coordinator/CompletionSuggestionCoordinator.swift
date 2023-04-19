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

import Combine
import Foundation
import SwiftUI
import UIKit
import WysiwygComposer

protocol CompletionSuggestionCoordinatorDelegate: AnyObject {
    func completionSuggestionCoordinator(_ coordinator: CompletionSuggestionCoordinator, didRequestMentionForMember member: MXRoomMember, textTrigger: String?)
    func completionSuggestionCoordinatorDidRequestMentionForRoom(_ coordinator: CompletionSuggestionCoordinator, textTrigger: String?)
    func completionSuggestionCoordinator(_ coordinator: CompletionSuggestionCoordinator, didRequestCommand command: String, textTrigger: String?)
    func completionSuggestionCoordinator(_ coordinator: CompletionSuggestionCoordinator, didUpdateViewHeight height: CGFloat)
}

struct CompletionSuggestionCoordinatorParameters {
    let mediaManager: MXMediaManager
    let room: MXRoom
    let userID: String
}

/// Wrapper around `CompletionSuggestionViewModelType.Context` to pass it through obj-c.
final class CompletionSuggestionViewModelContextWrapper: NSObject {
    let context: CompletionSuggestionViewModelType.Context

    init(context: CompletionSuggestionViewModelType.Context) {
        self.context = context
    }
}

final class CompletionSuggestionCoordinator: Coordinator, Presentable {
    // MARK: - Properties
    
    // MARK: Private
    
    private let parameters: CompletionSuggestionCoordinatorParameters
    
    private var completionSuggestionHostingController: UIHostingController<AnyView>
    private var completionSuggestionService: CompletionSuggestionServiceProtocol
    private var completionSuggestionViewModel: CompletionSuggestionViewModelProtocol
    private var roomMemberProvider: CompletionSuggestionCoordinatorRoomMemberProvider
    private var commandProvider: CompletionSuggestionCoordinatorCommandProvider

    private var cancellables = Set<AnyCancellable>()
    
    // MARK: Public

    // Must be used only internally
    var childCoordinators: [Coordinator] = []
    var completion: (() -> Void)?
    
    weak var delegate: CompletionSuggestionCoordinatorDelegate?
    
    // MARK: - Setup
    
    init(parameters: CompletionSuggestionCoordinatorParameters) {
        self.parameters = parameters
        
        roomMemberProvider = CompletionSuggestionCoordinatorRoomMemberProvider(room: parameters.room, userID: parameters.userID)
        commandProvider = CompletionSuggestionCoordinatorCommandProvider(room: parameters.room, userID: parameters.userID)
        completionSuggestionService = CompletionSuggestionService(roomMemberProvider: roomMemberProvider, commandProvider: commandProvider)
        
        let viewModel = CompletionSuggestionViewModel(completionSuggestionService: completionSuggestionService)
        let view = CompletionSuggestionList(viewModel: viewModel.context)
            .environmentObject(AvatarViewModel(avatarService: AvatarService(mediaManager: parameters.mediaManager)))
        
        completionSuggestionViewModel = viewModel
        completionSuggestionHostingController = VectorHostingController(rootView: view)
        
        completionSuggestionViewModel.completion = { [weak self] result in
            guard let self = self else {
                return
            }
            
            switch result {
            case .selectedItemWithIdentifier(let identifier):
                if identifier == CompletionSuggestionUserID.room {
                    self.delegate?.completionSuggestionCoordinatorDidRequestMentionForRoom(self, textTrigger: self.completionSuggestionService.currentTextTrigger)
                    return
                }
                
                if let member = self.roomMemberProvider.roomMembers.filter({ $0.userId == identifier }).first {
                    self.delegate?.completionSuggestionCoordinator(self, didRequestMentionForMember: member, textTrigger: self.completionSuggestionService.currentTextTrigger)
                } else if let command = self.commandProvider.commands.filter({ $0.name == identifier }).first {
                    self.delegate?.completionSuggestionCoordinator(self, didRequestCommand: command.name, textTrigger: self.completionSuggestionService.currentTextTrigger)
                }
            }
        }

        completionSuggestionService.items.sink { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.completionSuggestionCoordinator(self,
                                                     didUpdateViewHeight: self.calculateViewHeight())
        }.store(in: &cancellables)
    }
    
    func processTextMessage(_ textMessage: String) {
        completionSuggestionService.processTextMessage(textMessage)
    }

    func processSuggestionPattern(_ suggestionPattern: SuggestionPattern?) {
        completionSuggestionService.processSuggestionPattern(suggestionPattern)
    }

    // MARK: - Public

    func start() { }
    
    func toPresentable() -> UIViewController {
        completionSuggestionHostingController
    }

    func sharedContext() -> CompletionSuggestionViewModelContextWrapper {
        CompletionSuggestionViewModelContextWrapper(context: completionSuggestionViewModel.sharedContext)
    }

    // MARK: - Private

    private func calculateViewHeight() -> CGFloat {
        let viewModel = CompletionSuggestionViewModel(completionSuggestionService: completionSuggestionService)
        let view = CompletionSuggestionList(viewModel: viewModel.context)
            .environmentObject(AvatarViewModel(avatarService: AvatarService(mediaManager: parameters.mediaManager)))

        let controller = VectorHostingController(rootView: view)
        guard let view = controller.view else {
            return 0
        }
        view.isHidden = true

        toPresentable().view.addSubview(view)
        controller.didMove(toParent: toPresentable())

        view.setNeedsLayout()
        view.layoutIfNeeded()

        let result = view.intrinsicContentSize.height

        controller.didMove(toParent: nil)
        view.removeFromSuperview()

        return result
    }
}

private class CompletionSuggestionCoordinatorRoomMemberProvider: RoomMembersProviderProtocol {
    private let room: MXRoom
    private let userID: String
    
    var roomMembers: [MXRoomMember] = []
    var canMentionRoom = false
    
    init(room: MXRoom, userID: String) {
        self.room = room
        self.userID = userID
        updateWithPowerLevels()
    }
    
    /// Gets the power levels for the room to update suggestions accordingly.
    func updateWithPowerLevels() {
        room.state { [weak self] state in
            guard let self, let powerLevels = state?.powerLevels else { return }
            let userPowerLevel = powerLevels.powerLevelOfUser(withUserID: self.userID)
            let mentionRoomPowerLevel = powerLevels.minimumPowerLevel(forNotifications: kMXRoomPowerLevelNotificationsRoomKey,
                                                                      defaultPower: kMXRoomPowerLevelNotificationsRoomDefault)
            self.canMentionRoom = userPowerLevel >= mentionRoomPowerLevel
        }
    }
    
    func fetchMembers(_ members: @escaping ([RoomMembersProviderMember]) -> Void) {
        room.members { [weak self] roomMembers in
            guard let self = self, let joinedMembers = roomMembers?.joinedMembers else {
                return
            }
            self.roomMembers = joinedMembers
            members(self.roomMembersToProviderMembers(joinedMembers))
        } lazyLoadedMembers: { [weak self] lazyRoomMembers in
            guard let self = self, let joinedMembers = lazyRoomMembers?.joinedMembers else {
                return
            }
            self.roomMembers = joinedMembers
            members(self.roomMembersToProviderMembers(joinedMembers))
        } failure: { error in
            MXLog.error("[CompletionSuggestionCoordinatorRoomMemberProvider] Failed loading room", context: error)
        }
    }
    
    private func roomMembersToProviderMembers(_ roomMembers: [MXRoomMember]) -> [RoomMembersProviderMember] {
        roomMembers.map { RoomMembersProviderMember(userId: $0.userId, displayName: $0.displayname ?? "", avatarUrl: $0.avatarUrl ?? "") }
    }
}

private class CompletionSuggestionCoordinatorCommandProvider: CommandsProviderProtocol {
    private let room: MXRoom
    private let userID: String

    var commands: [(name: String, parametersFormat: String, description: String)] = []

    init(room: MXRoom, userID: String) {
        self.room = room
        self.userID = userID
        updateWithPowerLevels()
    }

    func updateWithPowerLevels() {
        // TODO: filter commands in terms of user power level ?
    }

    func fetchCommands(_ commands: @escaping ([CommandsProviderCommand]) -> Void) {
        self.commands = [
            (name: "/ban",
             parametersFormat: "<user-id> [reason]",
             description: "Bans user with given id"),
            (name: "/invite",
             parametersFormat: "<user-id>",
             description: "Invites user with given id to current room"),
            (name: "/join",
             parametersFormat: "<room-address>",
             description: "Joins room with given address"),
            (name: "/me",
             parametersFormat: "<message>",
             description: "Displays action")
        ]

        // TODO: get real data
        commands(self.commands.map { CommandsProviderCommand(name: $0.name,
                                                             parametersFormat: $0.parametersFormat,
                                                             description: $0.description) })
    }
}
