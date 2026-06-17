//! Training Tracker — a local, single-user native app for tracking the
//! trainings and certifications I want to complete. egui front end, SQLite
//! storage, no server.

mod db;
mod model;

use eframe::egui;

use db::Db;
use model::{Status, Training};

/// Database file, kept next to wherever the app is launched from.
const DB_PATH: &str = "training-tracker.db";

fn main() -> eframe::Result {
    let db = Db::open(DB_PATH).expect("failed to open database");

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([720.0, 560.0]),
        ..Default::default()
    };

    eframe::run_native(
        "Training Tracker",
        options,
        Box::new(|_cc| Ok(Box::new(TrackerApp::new(db)))),
    )
}

struct TrackerApp {
    db: Db,
    trainings: Vec<Training>,
    new_name: String,
    error: Option<String>,
}

impl TrackerApp {
    fn new(db: Db) -> Self {
        let mut app = Self {
            db,
            trainings: Vec::new(),
            new_name: String::new(),
            error: None,
        };
        app.reload();
        app
    }

    /// Refresh the in-memory list from the database.
    fn reload(&mut self) {
        match self.db.list() {
            Ok(list) => self.trainings = list,
            Err(e) => self.error = Some(format!("Load failed: {e}")),
        }
    }
}

impl eframe::App for TrackerApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("header").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.heading("Training Tracker");

            ui.horizontal(|ui| {
                ui.label("New training:");
                let resp = ui.text_edit_singleline(&mut self.new_name);
                let submit = ui.button("Add").clicked()
                    || (resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)));
                if submit {
                    let name = self.new_name.trim().to_string();
                    if !name.is_empty() {
                        match self.db.add(&name) {
                            Ok(_) => {
                                self.new_name.clear();
                                self.error = None;
                                self.reload();
                            }
                            Err(e) => self.error = Some(format!("Add failed: {e}")),
                        }
                    }
                }
            });

            if let Some(err) = &self.error {
                ui.colored_label(egui::Color32::RED, err);
            }
            ui.add_space(6.0);
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            if self.trainings.is_empty() {
                ui.add_space(20.0);
                ui.weak("No trainings yet — add one above.");
                return;
            }

            // Edits made this frame, applied after the render borrow ends.
            let mut dirty: Option<usize> = None;
            let mut to_delete: Option<i64> = None;

            egui::ScrollArea::vertical().show(ui, |ui| {
                for (idx, t) in self.trainings.iter_mut().enumerate() {
                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            if ui.text_edit_singleline(&mut t.name).changed() {
                                dirty = Some(idx);
                            }
                            ui.with_layout(
                                egui::Layout::right_to_left(egui::Align::Center),
                                |ui| {
                                    if ui.button("Delete").clicked() {
                                        to_delete = Some(t.id);
                                    }
                                },
                            );
                        });

                        ui.horizontal(|ui| {
                            egui::ComboBox::from_id_salt(("status", t.id))
                                .selected_text(t.status.label())
                                .show_ui(ui, |ui| {
                                    for s in Status::ALL {
                                        if ui
                                            .selectable_value(&mut t.status, s, s.label())
                                            .changed()
                                        {
                                            dirty = Some(idx);
                                        }
                                    }
                                });

                            if ui
                                .add(egui::Slider::new(&mut t.progress, 0..=100).suffix("%"))
                                .changed()
                            {
                                dirty = Some(idx);
                            }

                            ui.label("Target:");
                            if ui
                                .add(
                                    egui::TextEdit::singleline(&mut t.target_date)
                                        .hint_text("e.g. 2026-12")
                                        .desired_width(90.0),
                                )
                                .changed()
                            {
                                dirty = Some(idx);
                            }
                        });
                    });
                    ui.add_space(4.0);
                }
            });

            if let Some(idx) = dirty {
                let t = self.trainings[idx].clone();
                if let Err(e) = self.db.update(&t) {
                    self.error = Some(format!("Save failed: {e}"));
                }
            }
            if let Some(id) = to_delete {
                match self.db.delete(id) {
                    Ok(_) => self.reload(),
                    Err(e) => self.error = Some(format!("Delete failed: {e}")),
                }
            }
        });
    }
}
