import Defaults
import Foundation
import SwiftUI

struct SettingsView: View {
    #if os(macOS)
        private enum Tabs: Hashable {
            case instances, browsing, player, history, sponsorBlock, updates, help
        }

        @State private var selection = Tabs.instances
    #endif

    @Environment(\.colorScheme) private var colorScheme

    #if os(iOS)
        @Environment(\.presentationMode) private var presentationMode
    #endif

    @EnvironmentObject<AccountsModel> private var accounts

    @State private var presentingInstanceForm = false
    @State private var savedFormInstanceID: Instance.ID?

    @Default(.instances) private var instances

    var body: some View {
        #if os(macOS)
            TabView(selection: $selection) {
                Form {
                    InstancesSettings()
                        .environmentObject(accounts)
                }
                .tabItem {
                    Label("Instances", systemImage: "server.rack")
                }
                .tag(Tabs.instances)

                Form {
                    BrowsingSettings()
                }
                .tabItem {
                    Label("Browsing", systemImage: "list.and.film")
                }
                .tag(Tabs.browsing)

                Form {
                    PlayerSettings()
                }
                .tabItem {
                    Label("Player", systemImage: "play.rectangle")
                }
                .tag(Tabs.player)

                Form {
                    HistorySettings()
                }
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(Tabs.history)

                Form {
                    SponsorBlockSettings()
                }
                .tabItem {
                    Label("SponsorBlock", systemImage: "dollarsign.circle")
                }
                .tag(Tabs.sponsorBlock)

                Form {
                    UpdatesSettings()
                }
                .tabItem {
                    Label("Updates", systemImage: "gearshape.2")
                }
                .tag(Tabs.updates)

                Form {
                    Help()
                }
                .tabItem {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .tag(Tabs.help)
            }
            .padding(20)
            .frame(width: 480, height: windowHeight)
        #else
            NavigationView {
                List {
                    #if os(tvOS)
                        AccountSelectionView()
                    #endif

                    Section(header: Text("Instances")) {
                        ForEach(instances) { instance in
                            AccountsNavigationLink(instance: instance)
                        }
                        addInstanceButton
                    }

                    #if os(tvOS)
                        Divider()
                    #endif

                    Section {
                        #if os(tvOS)
                            NavigationLink {
                                EditFavorites()
                            } label: {
                                Label("Favorites", systemImage: "heart.fill")
                            }
                        #endif

                        NavigationLink {
                            BrowsingSettings()
                        } label: {
                            Label("Browsing", systemImage: "list.and.film")
                        }

                        NavigationLink {
                            PlayerSettings()
                        } label: {
                            Label("Player", systemImage: "play.rectangle")
                        }

                        NavigationLink {
                            HistorySettings()
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }

                        NavigationLink {
                            SponsorBlockSettings()
                        } label: {
                            Label("SponsorBlock", systemImage: "dollarsign.circle")
                        }
                    }

                    Section(footer: versionString) {
                        NavigationLink {
                            Help()
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        #if !os(tvOS)
                            Button("Done") {
                                presentationMode.wrappedValue.dismiss()
                            }
                            .keyboardShortcut(.cancelAction)
                        #endif
                    }
                }
                .frame(maxWidth: 1000)
                #if os(iOS)
                    .listStyle(.insetGrouped)
                #endif
            }
            .sheet(isPresented: $presentingInstanceForm) {
                InstanceForm(savedInstanceID: $savedFormInstanceID)
            }
            #if os(tvOS)
            .background(Color.background(scheme: colorScheme))
            #endif
        #endif
    }

    #if os(macOS)
        private var windowHeight: Double {
            switch selection {
            case .instances:
                return 390
            case .browsing:
                return 350
            case .player:
                return 450
            case .history:
                return 480
            case .sponsorBlock:
                return 660
            case .updates:
                return 200
            case .help:
                return 570
            }
        }
    #endif

    private var versionString: some View {
        Text("Yattee \(YatteeApp.version) (build \(YatteeApp.build))")
        #if os(tvOS)
            .foregroundColor(.secondary)
        #endif
    }

    private var addInstanceButton: some View {
        Button {
            presentingInstanceForm = true
        } label: {
            Label("Add Instance...", systemImage: "plus")
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .injectFixtureEnvironmentObjects()
        #if os(macOS)
            .frame(width: 600, height: 300)
        #endif
    }
}
