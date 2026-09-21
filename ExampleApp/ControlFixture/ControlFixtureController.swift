//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import UIKit

final class ControlFixtureController: UIViewController {
    private let statusLabel = UILabel()
    private let inputStatusLabel = UILabel()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let isDetail: Bool
    private var taps = 0
    private var navigationTaps = 0
    private var trapTaps = 0
    private var gestureTaps = 0

    init(isDetail: Bool = false) {
        self.isDetail = isDetail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNavigation()
        configureLayout()
        addInputControls()
        addGestureTargets()
        addScrollableButtons()
        updateStatus()
    }

    private func configureNavigation() {
        title = isDetail ? "Control Detail" : "Control"
        let action = UIAction { [weak self] _ in
            self?.navigationTaps += 1
            self?.updateStatus()
        }
        let button = UIBarButtonItem(title: "Nav action", primaryAction: action)
        button.accessibilityIdentifier = "poc.nav"
        navigationItem.rightBarButtonItem = button
    }

    private func configureLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "poc.status"
        scrollView.accessibilityLabel = "Fixture scroll area"
        scrollView.accessibilityIdentifier = "poc.scroll"
        contentStack.axis = .vertical
        contentStack.spacing = UIStackView.spacingUseSystem

        for subview in [statusLabel, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let margins = view.layoutMarginsGuide
        let content = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func addInputControls() {
        addButton("Tap counter", identifier: "poc.tap") { [weak self] in
            self?.recordTap()
        }

        inputStatusLabel.font = .preferredFont(forTextStyle: .body)
        inputStatusLabel.text = "Input: (empty)"
        inputStatusLabel.accessibilityIdentifier = "poc.inputStatus"
        inputStatusLabel.numberOfLines = 0
        contentStack.addArrangedSubview(inputStatusLabel)
        contentStack.addArrangedSubview(makeTextField("Search query", identifier: "poc.query"))
        contentStack.addArrangedSubview(makeTextField("Password", identifier: "poc.password", isSecure: true))

        let notes = UITextView()
        notes.font = .preferredFont(forTextStyle: .body)
        notes.accessibilityLabel = "Notes"
        notes.accessibilityIdentifier = "poc.notes"
        notes.delegate = self
        notes.heightAnchor.constraint(equalToConstant: UIFont.preferredFont(forTextStyle: .body).lineHeight * 3).isActive = true
        contentStack.addArrangedSubview(notes)

        if !isDetail {
            addButton("Open detail", identifier: "poc.push") { [weak self] in
                self?.navigationController?.pushViewController(ControlFixtureController(isDetail: true), animated: true)
            }
        }
    }

    private func makeTextField(_ label: String, identifier: String, isSecure: Bool = false) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.placeholder = label
        field.accessibilityLabel = label
        field.accessibilityIdentifier = identifier
        field.isSecureTextEntry = isSecure
        field.addAction(UIAction { [weak self, weak field] _ in
            self?.inputStatusLabel.text = isSecure ? "Password edited" : "Input: \(field?.text ?? "")"
        }, for: .editingChanged)
        return field
    }

    private func addGestureTargets() {
        let accessible = makeLabel("Accessible tap target", identifier: "poc.gesture")
        accessible.isAccessibilityElement = true
        accessible.accessibilityLabel = "Accessible tap target"
        accessible.isUserInteractionEnabled = true
        accessible.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(accessibleTapped(_:))))
        contentStack.addArrangedSubview(accessible)

        let multi = makeLabel("Multi-tap target", identifier: "poc.multitap")
        multi.isAccessibilityElement = true
        multi.isUserInteractionEnabled = true
        multi.accessibilityLabel = "Multi-tap target"
        for fingers in 1...5 {
            for taps in 1...3 {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(multiTapped(_:)))
                recognizer.numberOfTouchesRequired = fingers
                recognizer.numberOfTapsRequired = taps
                multi.addGestureRecognizer(recognizer)
            }
        }
        // Delay lower-count recognizers until higher counts fail, as in a real multi-tap control.
        for case let lower as UITapGestureRecognizer in multi.gestureRecognizers ?? [] {
            for case let higher as UITapGestureRecognizer in multi.gestureRecognizers ?? [] {
                if lower.numberOfTouchesRequired == higher.numberOfTouchesRequired,
                   lower.numberOfTapsRequired < higher.numberOfTapsRequired {
                    lower.require(toFail: higher)
                }
            }
        }
        contentStack.addArrangedSubview(multi)

        let readOnly = makeLabel("Read-only label (not a button)", identifier: "poc.readonly")
        contentStack.addArrangedSubview(readOnly)

        let trap = makeLabel("Non-accessible gesture label", identifier: "poc.trap")
        trap.isAccessibilityElement = false
        trap.isUserInteractionEnabled = true
        trap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(trapTapped)))
        contentStack.addArrangedSubview(trap)
    }

    private func makeLabel(_ text: String, identifier: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.accessibilityIdentifier = identifier
        return label
    }

    private func addScrollableButtons() {
        for index in 1...80 {
            addButton("Item \(index)", identifier: "poc.item.\(index)") { [weak self] in
                self?.recordTap()
            }
        }
    }

    private func addButton(_ title: String, identifier: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.configuration = .bordered()
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        contentStack.addArrangedSubview(button)
    }

    private func recordTap() {
        taps += 1
        updateStatus()
    }

    @objc private func accessibleTapped(_ recognizer: UITapGestureRecognizer) {
        gestureTaps += 1
        updateStatus()
        guard let target = recognizer.view else { return }
        let point = recognizer.location(in: target)
        inputStatusLabel.text = String(format: "Tap position: %.2f, %.2f", point.x / target.bounds.width, point.y / target.bounds.height)
    }

    @objc private func multiTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        inputStatusLabel.text = "Gesture: \(recognizer.numberOfTouchesRequired) fingers × \(recognizer.numberOfTapsRequired) taps"
    }

    @objc private func trapTapped() {
        trapTaps += 1
        updateStatus()
    }

    private func updateStatus() {
        statusLabel.text = "Taps: \(taps) · Nav: \(navigationTaps) · Trap: \(trapTaps) · Gesture: \(gestureTaps)"
    }
}

extension ControlFixtureController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        inputStatusLabel.text = "Notes: \(textView.text ?? "")"
    }
}
