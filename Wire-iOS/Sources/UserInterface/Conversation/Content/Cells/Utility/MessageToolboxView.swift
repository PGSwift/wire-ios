//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import zmessaging
import Cartography
import Classy
import TTTAttributedLabel


extension ZMConversationMessage {

    fileprivate func formattedReceivedDate() -> String? {
        return serverTimestamp.map(formattedDate)
    }

    fileprivate func formattedEditedDate() -> String? {
        return updatedAt.map(formattedDate)
    }

    private func formattedDate(_ date: Date) -> String {
        let timeString = Message.longVersionTimeFormatter().string(from: date)
        let oneDayInSeconds = 24.0 * 60.0 * 60.0
        let shouldShowDate = fabs(date.timeIntervalSinceReferenceDate - Date().timeIntervalSinceReferenceDate) > oneDayInSeconds
        if shouldShowDate {
            let dateString = Message.shortVersionDateFormatter().string(from: date)
            return dateString + " " + timeString
        } else {
            return timeString
        }
    }
}


@objc public protocol MessageToolboxViewDelegate: NSObjectProtocol {
    func messageToolboxViewDidSelectLikers(_ messageToolboxView: MessageToolboxView)
    func messageToolboxViewDidSelectResend(_ messageToolboxView: MessageToolboxView)
}

@objc open class MessageToolboxView: UIView {
    fileprivate static let resendLink = URL(string: "settings://resend-message")!

    private static let ephemeralTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    open let statusLabel = TTTAttributedLabel(frame: CGRect.zero)
    open let reactionsView = ReactionsView()
    fileprivate let labelClipView = UIView()
    fileprivate var tapGestureRecogniser: UITapGestureRecognizer!
    open let likeTooltipArrow = UILabel()
    
    open weak var delegate: MessageToolboxViewDelegate?

    fileprivate var previousLayoutBounds: CGRect = CGRect.zero
    
    fileprivate(set) weak var message: ZMConversationMessage?
    
    fileprivate var forceShowTimestamp: Bool = false
    
    override init(frame: CGRect) {
        
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.accessibilityElementsHidden = false
        
        CASStyler.default().styleItem(self)
        
        setupViews()
        createConstraints()
        
        tapGestureRecogniser = UITapGestureRecognizer(target: self, action: #selector(MessageToolboxView.onTapContent(_:)))
        tapGestureRecogniser.delegate = self
        addGestureRecognizer(tapGestureRecogniser)
    }
    
    private func setupViews() {
        reactionsView.accessibilityIdentifier = "reactionsView"
        
        labelClipView.clipsToBounds = true
        labelClipView.isAccessibilityElement = true
        labelClipView.isUserInteractionEnabled = true
        
        statusLabel.delegate = self
        statusLabel.extendsLinkTouchArea = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.verticalAlignment = .center
        statusLabel.isAccessibilityElement = true
        statusLabel.accessibilityLabel = "DeliveryStatus"
        statusLabel.lineBreakMode = NSLineBreakMode.byTruncatingMiddle
        statusLabel.linkAttributes = [NSUnderlineStyleAttributeName: NSUnderlineStyle.styleSingle.rawValue,
                                      NSForegroundColorAttributeName: UIColor(for: .vividRed)]
        statusLabel.activeLinkAttributes = [NSUnderlineStyleAttributeName: NSUnderlineStyle.styleSingle.rawValue,
                                            NSForegroundColorAttributeName: UIColor(for: .vividRed).withAlphaComponent(0.5)]
        
        labelClipView.addSubview(statusLabel)
        likeTooltipArrow.accessibilityIdentifier = "likeTooltipArrow"
        likeTooltipArrow.text = "←"
        
        [likeTooltipArrow, reactionsView, labelClipView].forEach(addSubview)
    }
    
    private func createConstraints() {
        constrain(self, reactionsView, statusLabel, labelClipView, likeTooltipArrow) { selfView, reactionsView, statusLabel, labelClipView, likeTooltipArrow in
            labelClipView.left == selfView.leftMargin
            labelClipView.centerY == selfView.centerY
            labelClipView.right == selfView.rightMargin
            
            statusLabel.left == labelClipView.left
            statusLabel.top == labelClipView.top
            statusLabel.bottom == labelClipView.bottom
            statusLabel.right <= reactionsView.left
            
            reactionsView.right == selfView.rightMargin
            reactionsView.centerY == selfView.centerY
            
            likeTooltipArrow.centerY == statusLabel.centerY
            likeTooltipArrow.right == selfView.leftMargin - 8
        }
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override var intrinsicContentSize : CGSize {
        return CGSize(width: UIViewNoIntrinsicMetric, height: 28)
    }
    
    open func configureForMessage(_ message: ZMConversationMessage, forceShowTimestamp: Bool, animated: Bool = false) {
        self.forceShowTimestamp = forceShowTimestamp
        self.message = message
        
        let canShowTooltip = !Settings.shared().likeTutorialCompleted && !message.hasReactions() && message.canBeLiked
        
        // Show like tip
        if let sender = message.sender, !sender.isSelfUser && canShowTooltip {
            showReactionsView(message.hasReactions(), animated: false)
            self.likeTooltipArrow.isHidden = false
            self.tapGestureRecogniser.isEnabled = message.hasReactions()
            self.configureLikeTip(message, animated: animated)
        }
        else {
            self.likeTooltipArrow.isHidden = true
            if !self.forceShowTimestamp && message.hasReactions() {
                self.configureLikedState(message)
                self.layoutIfNeeded()
                showReactionsView(true, animated: animated)
                self.configureReactions(message, animated: animated)
                self.tapGestureRecogniser.isEnabled = true
            }
            else {
                self.layoutIfNeeded()
                showReactionsView(false, animated: animated)
                self.configureTimestamp(message, animated: animated)
                self.tapGestureRecogniser.isEnabled = false
            }
        }
    }
    
    fileprivate func showReactionsView(_ show: Bool, animated: Bool) {
        guard show == reactionsView.isHidden else { return }

        if show {
            reactionsView.alpha = 0
            reactionsView.isHidden = false
        }

        let animations = {
            self.reactionsView.alpha = show ? 1 : 0
        }

        UIView.animate(withDuration: animated ? 0.2 : 0, animations: animations, completion: { _ in
            self.reactionsView.isHidden = !show
        }) 
    }
    
    fileprivate func configureLikedState(_ message: ZMConversationMessage) {
        self.reactionsView.likers = message.likers()
    }
    
    fileprivate func timestampString(_ message: ZMConversationMessage) -> String? {
        let timestampString: String?

        if let editedTimeString = message.formattedEditedDate() {
            timestampString = String(format: "content.system.edited_message_prefix_timestamp".localized, editedTimeString)
        } else if let dateTimeString = message.formattedReceivedDate() {
            if let systemMessage = message as? ZMSystemMessage , systemMessage.systemMessageType == .messageDeletedForEveryone {
                timestampString = String(format: "content.system.deleted_message_prefix_timestamp".localized, dateTimeString)
            } else {
                timestampString = dateTimeString
            }
        } else {
            timestampString = .none
        }
        
        return timestampString
    }
    
    fileprivate func configureReactions(_ message: ZMConversationMessage, animated: Bool = false) {
        guard !self.bounds.equalTo(CGRect.zero) else {
            return
        }
        
        let likers = message.likers()
        
        let likersNames = likers.map { user in
            return user.displayName
        }.joined(separator: ", ")
        
        let attributes = [NSFontAttributeName: statusLabel.font, NSForegroundColorAttributeName: statusLabel.textColor] as [String : AnyObject]
        let likersNamesAttributedString = likersNames && attributes

        let framesetter = CTFramesetterCreateWithAttributedString(likersNamesAttributedString)
        let targetSize = CGSize(width: 10000, height: CGFloat.greatestFiniteMagnitude)
        let labelSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, likersNamesAttributedString.length), nil, targetSize, nil)

        let attributedText: NSAttributedString
        if labelSize.width > (labelClipView.bounds.width - reactionsView.bounds.width) {
            let likersCount = String(format: "participants.people.count".localized, likers.count)
            attributedText = likersCount && attributes
        }
        else {
            attributedText = likersNamesAttributedString
        }

        if let currentText = self.statusLabel.attributedText, currentText.string == attributedText.string {
            return
        }
        
        let changeBlock = {
            self.statusLabel.attributedText = attributedText
            self.accessibilityValue = self.statusLabel.attributedText.string
        }
        
        if animated {
            statusLabel.wr_animateSlideTo(.down, newState: changeBlock)
        }
        else {
            changeBlock()
        }
    }

    public func updateTimestamp(_ message: ZMConversationMessage) {
        configureTimestamp(message)
    }
    
    fileprivate func configureTimestamp(_ message: ZMConversationMessage, animated: Bool = false) {
        var deliveryStateString: String? = .none
        
        if let sender = message.sender, sender.isSelfUser {
            switch message.deliveryState {
            case .pending:
                deliveryStateString = "content.system.pending_message_timestamp".localized
            case .delivered:
                deliveryStateString = "content.system.message_delivered_timestamp".localized
            case .sent:
                deliveryStateString = "content.system.message_sent_timestamp".localized
            case .failedToSend:
                deliveryStateString = "content.system.failedtosend_message_timestamp".localized + " " + "content.system.failedtosend_message_timestamp_resend".localized
            default:
                deliveryStateString = .none
            }
        }

        let showDestructionTimer = message.isEphemeral && !message.isObfuscated && nil != message.destructionDate
        if let destructionDate = message.destructionDate, showDestructionTimer {
            let remaining = destructionDate.timeIntervalSinceNow + 1 // We need to add one second to start with the correct value
            deliveryStateString = MessageToolboxView.ephemeralTimeFormatter.string(from: remaining)
        }

        let finalText: String
        
        if let timestampString = self.timestampString(message), message.deliveryState == .delivered || message.deliveryState == .sent {
            if let deliveryStateString = deliveryStateString {
                finalText = timestampString + " ・ " + deliveryStateString
            }
            else {
                finalText = timestampString
            }
        }
        else {
            finalText = (deliveryStateString ?? "")
        }
        
        let attributedText = NSMutableAttributedString(attributedString: finalText && [NSFontAttributeName: statusLabel.font, NSForegroundColorAttributeName: statusLabel.textColor])
        
        if message.deliveryState == .failedToSend {
            let linkRange = (finalText as NSString).range(of: "content.system.failedtosend_message_timestamp_resend".localized)
            attributedText.addAttributes([NSLinkAttributeName: type(of: self).resendLink], range: linkRange)
        }

        if showDestructionTimer, let stateString = deliveryStateString {
            let ephemeralColor = UIColor.wr_color(fromColorScheme: ColorSchemeColorAccent)
            attributedText.addAttributes([NSForegroundColorAttributeName: ephemeralColor], to: stateString)
        }
        
        if let currentText = self.statusLabel.attributedText, currentText.string == attributedText.string {
            return
        }
        
        let changeBlock =  {
            self.statusLabel.attributedText = attributedText
            self.accessibilityValue = self.statusLabel.attributedText.string
            self.statusLabel.addLinks()
        }
        
        if animated {
            statusLabel.wr_animateSlideTo(.up, newState: changeBlock)
        }
        else {
            changeBlock()
        }
    }
    
    fileprivate func configureLikeTip(_ message: ZMConversationMessage, animated: Bool = false) {
        let likeTooltipText = "content.system.like_tooltip".localized
        let attributes = [NSFontAttributeName: statusLabel.font, NSForegroundColorAttributeName: statusLabel.textColor] as [String : AnyObject]
        let attributedText = likeTooltipText && attributes

        if let currentText = self.statusLabel.attributedText , currentText.string == attributedText.string {
            return
        }
        
        let changeBlock =  {
            self.statusLabel.attributedText = attributedText
            self.accessibilityValue = self.statusLabel.attributedText.string
        }
        
        if animated {
            statusLabel.wr_animateSlideTo(.up, newState: changeBlock)
        }
        else {
            changeBlock()
        }
    }
    
    open override func layoutSubviews() {
        super.layoutSubviews()
        guard let message = self.message , !self.bounds.equalTo(self.previousLayoutBounds) else {
            return
        }
        
        self.previousLayoutBounds = self.bounds
        
        self.configureForMessage(message, forceShowTimestamp: self.forceShowTimestamp)
    }
    
    
    // MARK: - Events

    @objc func onTapContent(_ sender: UITapGestureRecognizer!) {
        guard !forceShowTimestamp else { return }
        if let message = self.message , !message.likers().isEmpty {
            self.delegate?.messageToolboxViewDidSelectLikers(self)
        }
    }
    
    @objc func prepareForReuse() {
        self.message = nil
    }
}


extension MessageToolboxView: TTTAttributedLabelDelegate {
    
    // MARK: - TTTAttributedLabelDelegate
    
    public func attributedLabel(_ label: TTTAttributedLabel!, didSelectLinkWith URL: Foundation.URL!) {
        if URL == type(of: self).resendLink {
            self.delegate?.messageToolboxViewDidSelectResend(self)
        }
    }
}

extension MessageToolboxView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return gestureRecognizer.isEqual(self.tapGestureRecogniser)
    }
}
