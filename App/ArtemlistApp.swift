import SwiftUI
import SwiftData
import PhotosUI
import UserNotifications

@Model final class Note {
    var title = ""
    var text = ""
    var link = ""
    var updated = Date()
    var reminder: Date?
    var repeatRule = "Нет"
    var notificationID = UUID().uuidString
    @Attribute(.externalStorage) var photos: [Data] = []
    init() {}
}

@main struct ArtemlistApp: App {
    var body: some Scene {
        WindowGroup { NotesView() }
            .modelContainer(for: Note.self)
    }
}

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.updated, order: .reverse) private var notes: [Note]
    @State private var search = ""
    @State private var remindersOnly = false
    @State private var selected: Note?
    var filtered: [Note] {
        notes.filter { (!remindersOnly || $0.reminder != nil) && (search.isEmpty || ($0.title + " " + $0.text + " " + $0.link).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("Раздел", selection: $remindersOnly) {
                    Text("Заметки").tag(false)
                    Text("Напоминания").tag(true)
                }.pickerStyle(.segmented).listRowSeparator(.hidden)
                ForEach(filtered) { note in
                    Button { selected = note } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.title.isEmpty ? "Без названия" : note.title).font(.headline).foregroundStyle(.primary)
                            if !note.text.isEmpty { Text(note.text).lineLimit(2).foregroundStyle(.secondary) }
                            HStack {
                                if !note.link.isEmpty { Image(systemName: "link") }
                                if !note.photos.isEmpty { Label("\(note.photos.count)", systemImage: "photo") }
                                if let date = note.reminder { Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "bell").foregroundStyle(.orange) }
                            }.font(.caption)
                        }.padding(.vertical, 6)
                    }.swipeActions {
                        Button("Удалить", role: .destructive) {
                            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [note.notificationID])
                            context.delete(note)
                        }
                    }
                }
            }.listStyle(.plain)
                .overlay { if filtered.isEmpty { ContentUnavailableView(search.isEmpty ? "Здесь появятся ваши заметки" : "Ничего не найдено", systemImage: "note.text", description: Text("Сохраняйте мысли, ссылки и скриншоты" )).allowsHitTesting(false).padding(.top, 70) } }
                .searchable(text: $search, prompt: "Поиск по заметкам и ссылкам")
                .navigationTitle("Artemlist")
                .safeAreaInset(edge: .bottom) {
                    Button { let note = Note(); context.insert(note); selected = note } label: {
                        Label("Новая заметка", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding()
                    }.buttonStyle(.borderedProminent).padding().background(.bar)
                }
                .sheet(item: $selected) { note in NavigationStack { Editor(note: note) } }
        }.tint(.indigo)
    }
}

struct Editor: View {
    @Bindable var note: Note
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("Название", text: $note.title).font(.title2.bold())
                TextField("Что хотите сохранить?", text: $note.text, axis: .vertical).lineLimit(6...20)
            }
            Section("Ссылка") {
                TextField("https://…", text: $note.link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let url = URL(string: note.link), ["https", "http"].contains(url.scheme ?? "") { Link("Открыть страницу", destination: url) }
            }
            Section("Скриншоты и фото") {
                PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) { Label("Добавить из Фото", systemImage: "photo.badge.plus") }
                ForEach(Array(note.photos.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                        Button("Удалить фото", role: .destructive) { note.photos.remove(at: index) }
                    }
                }
            }
            Section("Напоминание") {
                Toggle("Напомнить", isOn: Binding(get: { note.reminder != nil }, set: { note.reminder = $0 ? Date().addingTimeInterval(3600) : nil }))
                if note.reminder != nil {
                    DatePicker("Когда", selection: Binding(get: { note.reminder ?? Date() }, set: { note.reminder = $0 }))
                    Picker("Повтор", selection: $note.repeatRule) { ForEach(["Нет", "Ежедневно", "Еженедельно"], id: \.self) { Text($0) } }
                    Button("Отложить на час") { note.reminder = Date().addingTimeInterval(3600) }
                    Button("Готово") { note.reminder = nil }
                }
            }
            Text("Сохраняется на вашем iPhone. Доступно без интернета.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Заметка").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { Task { await save() } } } }
            .interactiveDismissDisabled()
            .onChange(of: picked) { _, items in
                Task {
                    do {
                        for item in items { if let data = try await item.loadTransferable(type: Data.self) { note.photos.append(data) } }
                        picked = []
                    } catch { self.error = "Не удалось загрузить фото: \(error.localizedDescription)" }
                }
            }
            .alert("Не удалось завершить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Понятно") { error = nil } } message: { Text(error ?? "") }
    }
    @MainActor private func save() async {
        note.updated = Date()
        do {
            try context.save()
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [note.notificationID])
            if let date = note.reminder {
                guard date > Date() else { error = "Выберите будущее время напоминания."; return }
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { error = "Разрешите уведомления для Artemlist в настройках iPhone. Заметка сохранена."; return }
                let content = UNMutableNotificationContent()
                content.title = note.title.isEmpty ? "Artemlist" : note.title
                content.body = String(note.text.prefix(200))
                content.sound = .default
                var components: DateComponents
                if note.repeatRule == "Ежедневно" { components = Calendar.current.dateComponents([.hour, .minute], from: date) }
                else if note.repeatRule == "Еженедельно" { components = Calendar.current.dateComponents([.weekday, .hour, .minute], from: date) }
                else { components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date) }
                try await center.add(UNNotificationRequest(identifier: note.notificationID, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: note.repeatRule != "Нет")))
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
