#include <opencv2/opencv.hpp>
#include <vector>
#include <iostream>
#include <algorithm>
#include <cmath>
#include <string>

#ifdef _WIN32
  #include <windows.h>
  #define DLLEXPORT __declspec(dllexport)
#else
  #define DLLEXPORT
#endif

constexpr int PIANO_TOTAL_KEYS = 61;
constexpr int PIANO_BASE_MIDI = 36;

struct FingerData {
    int x;
    int y;
    int key_index;
    int string_index;
    int midi_note;
    int is_striking;
};

struct AirMusicianData {
    int mode;
    int play_style;
    int count;
    int error;
    int is_strummed;
    int strum_velocity;
    int pitch_bend;
    
    int score;
    int combo;
    int judge_type;
    
    FingerData fingers[10];
};

struct NoteGuide {
    int midi_note;
    int key_index;
    int string_index;
    double time_diff;
};

static cv::VideoCapture* g_cap0 = nullptr;
static cv::VideoCapture* g_cap1 = nullptr;

static int g_current_mode = 0;
static int g_current_play_style = 0;
static int g_prev_right_y = -1;
static int g_base_left_y = -1;

static std::vector<NoteGuide> g_active_guides;

int getCentersByHSV(const cv::Mat& frame, const cv::Scalar& low, const cv::Scalar& high, std::vector<cv::Point>& out_pts, int max_count = 10) {
    out_pts.clear();
    if (frame.empty()) return 0;

    cv::Mat hsv, mask;
    cv::cvtColor(frame, hsv, cv::COLOR_BGR2HSV);
    cv::inRange(hsv, low, high, mask);

    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5));
    cv::morphologyEx(mask, mask, cv::MORPH_OPEN, kernel);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    std::sort(contours.begin(), contours.end(), [](const std::vector<cv::Point>& a, const std::vector<cv::Point>& b) {
        return cv::contourArea(a) > cv::contourArea(b);
    });

    for (const auto& contour : contours) {
        if (out_pts.size() >= static_cast<size_t>(max_count)) break;
        if (cv::contourArea(contour) > 200.0) {
            cv::Moments m = cv::moments(contour);
            if (m.m00 != 0) {
                out_pts.push_back(cv::Point(static_cast<int>(m.m10 / m.m00), static_cast<int>(m.m01 / m.m00)));
            }
        }
    }

    std::sort(out_pts.begin(), out_pts.end(), [](const cv::Point& a, const cv::Point& b) {
        return a.x < b.x;
    });

    return static_cast<int>(out_pts.size());
}

void draw_guitar_fretboard(cv::Mat& frame) {
    if (frame.empty()) return;

    int cols = frame.cols;
    int rows = frame.rows;

    for (int i = 1; i <= 6; ++i) {
        int y = static_cast<int>((double)(i - 0.5) / 6.0 * rows);
        cv::Scalar color = (i == 1) ? cv::Scalar(0, 255, 255) : cv::Scalar(200, 200, 200);
        cv::line(frame, cv::Point(0, y), cv::Point(cols, y), color, (i <= 3) ? 1 : 2);
        cv::putText(frame, std::to_string(i) + " Str", cv::Point(10, y - 5),
                    cv::FONT_HERSHEY_SIMPLEX, 0.45, color, 1, cv::LINE_AA);
    }

    for (int j = 1; j <= 12; ++j) {
        int x = static_cast<int>((double)j / 12.0 * cols);
        cv::line(frame, cv::Point(x, 0), cv::Point(x, rows), cv::Scalar(120, 120, 120), 1);
        cv::putText(frame, std::to_string(j), cv::Point(x - 20, rows - 10),
                    cv::FONT_HERSHEY_SIMPLEX, 0.4, cv::Scalar(180, 180, 180), 1, cv::LINE_AA);
    }
}

void draw_piano_keyboard_overlay(cv::Mat& frame, int total_keys = 21) {
    if (frame.empty()) return;
    int height = frame.rows;
    int width = frame.cols;
    int key_width = width / total_keys;
    int piano_y = height * 3 / 4;

    static const char* note_names[] = { "C", "D", "E", "F", "G", "A", "B" };

    for (int i = 0; i < total_keys; ++i) {
        int x = i * key_width;
        cv::line(frame, cv::Point(x, piano_y), cv::Point(x, height), cv::Scalar(255, 255, 255), 1);

        std::string note_str = note_names[i % 7];
        cv::putText(frame, note_str, cv::Point(x + key_width / 4, height - 12),
                    cv::FONT_HERSHEY_SIMPLEX, 0.45, cv::Scalar(220, 220, 220), 1, cv::LINE_AA);
    }

    cv::line(frame, cv::Point(0, piano_y), cv::Point(width, piano_y), cv::Scalar(0, 255, 0), 2);
}

extern "C" {

DLLEXPORT int init_cameras(int cam0_id, int cam1_id, const char* model_path) {
    if (g_cap0) { g_cap0->release(); delete g_cap0; g_cap0 = nullptr; }
    if (g_cap1) { g_cap1->release(); delete g_cap1; g_cap1 = nullptr; }

    g_cap0 = new cv::VideoCapture(cam0_id, cv::CAP_DSHOW);
    if (!g_cap0->isOpened()) g_cap0->open(cam0_id, cv::CAP_ANY);

    if (cam1_id >= 0) {
        g_cap1 = new cv::VideoCapture(cam1_id, cv::CAP_DSHOW);
        if (!g_cap1->isOpened()) g_cap1->open(cam1_id, cv::CAP_ANY);
    }

    if (!g_cap0->isOpened()) return -1;
    return 0;
}

DLLEXPORT void set_mode(int mode, int play_style) {
    g_current_mode = mode;
    g_current_play_style = play_style;
    g_prev_right_y = -1;
    g_base_left_y = -1;
}

DLLEXPORT void clear_guides() {
    g_active_guides.clear();
}

DLLEXPORT void add_guide(int midi_note, int key_idx, int string_idx, double time_diff) {
    NoteGuide g;
    g.midi_note = midi_note;
    g.key_index = key_idx;
    g.string_index = string_idx;
    g.time_diff = time_diff;
    g_active_guides.push_back(g);
}

DLLEXPORT void process_frame(void* buffer) {
    if (!buffer) return;

    AirMusicianData* data = reinterpret_cast<AirMusicianData*>(buffer);
    data->error = 0;
    data->mode = g_current_mode;
    data->play_style = g_current_play_style;
    data->is_strummed = 0;
    data->strum_velocity = 0;
    data->pitch_bend = 0;
    data->count = 0;

    if (!g_cap0 || !g_cap0->isOpened()) {
        data->error = 1;
        return;
    }

    cv::Mat frame0, frame1;
    *g_cap0 >> frame0;
    if (g_cap1 && g_cap1->isOpened()) *g_cap1 >> frame1;

    if (frame0.empty()) {
        data->error = 1;
        return;
    }

    if (g_current_mode == 0) {
        draw_piano_keyboard_overlay(frame0);

        std::vector<cv::Point> pts0;
        int count0 = getCentersByHSV(frame0, cv::Scalar(35, 80, 80), cv::Scalar(85, 255, 255), pts0, 10);
        data->count = count0;

        std::vector<cv::Point> pts1;
        if (!frame1.empty()) {
            getCentersByHSV(frame1, cv::Scalar(35, 80, 80), cv::Scalar(85, 255, 255), pts1, 10);
        }

        double key_w = static_cast<double>(frame0.cols) / PIANO_TOTAL_KEYS;
        int judge_line_cam0_y = frame0.rows - 80;
        int judge_line_cam1_y = (!frame1.empty()) ? (frame1.rows - 100) : judge_line_cam0_y;

        if (g_current_play_style == 1) {
            cv::line(frame0, cv::Point(0, judge_line_cam0_y), cv::Point(frame0.cols, judge_line_cam0_y), cv::Scalar(0, 255, 255), 3);

            for (const auto& guide : g_active_guides) {
                int target_x = static_cast<int>(guide.key_index * key_w + key_w / 2);
                int note_y = static_cast<int>(judge_line_cam0_y - (guide.time_diff * 200));

                if (note_y > 0 && note_y < frame0.rows) {
                    cv::circle(frame0, cv::Point(target_x, note_y), 10, cv::Scalar(0, 200, 255), -1);
                    cv::circle(frame0, cv::Point(target_x, note_y), 12, cv::Scalar(255, 255, 255), 2);
                }
            }
        }

        for (int i = 0; i < count0; ++i) {
            data->fingers[i].x = pts0[i].x;
            data->fingers[i].y = pts0[i].y;

            int k_idx = std::clamp(static_cast<int>(pts0[i].x / key_w), 0, PIANO_TOTAL_KEYS - 1);
            data->fingers[i].key_index = k_idx;
            data->fingers[i].midi_note = PIANO_BASE_MIDI + k_idx;

            if (!pts1.empty() && i < static_cast<int>(pts1.size())) {
                data->fingers[i].is_striking = (pts1[i].y > judge_line_cam1_y) ? 1 : 0;
            } else {
                data->fingers[i].is_striking = (pts0[i].y > judge_line_cam0_y) ? 1 : 0;
            }

            cv::circle(frame0, pts0[i], 8, cv::Scalar(0, 255, 0), -1);
        }

        if (!frame1.empty()) {
            cv::line(frame1, cv::Point(0, judge_line_cam1_y), cv::Point(frame1.cols, judge_line_cam1_y), cv::Scalar(0, 0, 255), 2);
            for (const auto& pt : pts1) {
                cv::circle(frame1, pt, 8, cv::Scalar(255, 255, 0), -1);
            }
            cv::putText(frame1, "[Cam 1: Side Height Sensor]", cv::Point(10, 30), cv::FONT_HERSHEY_SIMPLEX, 0.5, cv::Scalar(255, 255, 0), 1);
            cv::imshow("Piano Side - Height Sensor (Cam 1)", frame1);
        }

        if (g_current_play_style == 1) {
            cv::putText(frame0, "SCORE: " + std::to_string(data->score), cv::Point(20, 40), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(255, 255, 255), 2);
            cv::putText(frame0, "COMBO: " + std::to_string(data->combo), cv::Point(20, 80), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(0, 255, 255), 2);

            if (data->judge_type == 1)      cv::putText(frame0, "PERFECT!!", cv::Point(frame0.cols/2 - 80, 150), cv::FONT_HERSHEY_SIMPLEX, 1.2, cv::Scalar(0, 255, 0), 3);
            else if (data->judge_type == 2) cv::putText(frame0, "GREAT!", cv::Point(frame0.cols/2 - 60, 150), cv::FONT_HERSHEY_SIMPLEX, 1.2, cv::Scalar(0, 255, 255), 3);
            else if (data->judge_type == 3) cv::putText(frame0, "MISS...", cv::Point(frame0.cols/2 - 60, 150), cv::FONT_HERSHEY_SIMPLEX, 1.2, cv::Scalar(0, 0, 255), 3);
        } else {
            cv::putText(frame0, "[FREE PIANO MODE]", cv::Point(20, 40), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(0, 255, 0), 2);
        }

        cv::imshow("Air Musician - Piano Front (Cam 0)", frame0);
    }
    else if (g_current_mode == 1) {
        draw_guitar_fretboard(frame0);

        std::vector<cv::Point> pts_red;
        getCentersByHSV(frame0, cv::Scalar(0, 120, 120), cv::Scalar(10, 255, 255), pts_red, 1);
        if (!pts_red.empty()) {
            if (g_prev_right_y >= 0) {
                int speed = pts_red[0].y - g_prev_right_y;
                if (speed > 25) {
                    data->is_strummed = 1;
                    data->strum_velocity = std::clamp(speed * 3, 50, 127);
                    g_base_left_y = -1;
                }
            }
            g_prev_right_y = pts_red[0].y;
            cv::circle(frame0, pts_red[0], 10, cv::Scalar(0, 0, 255), -1);
        } else {
            g_prev_right_y = -1;
        }

        if (!frame1.empty()) {
            draw_guitar_fretboard(frame1);

            std::vector<cv::Point> pts_green;
            int count = getCentersByHSV(frame1, cv::Scalar(35, 80, 80), cv::Scalar(85, 255, 255), pts_green, 10);
            data->count = count;

            if (count > 0) {
                int current_y = pts_green[0].y;
                if (g_base_left_y < 0) g_base_left_y = current_y;
                int delta_y = g_base_left_y - current_y;
                data->pitch_bend = std::clamp(delta_y * 120, -8192, 8191);

                for (int i = 0; i < count; ++i) {
                    int fret = std::clamp(static_cast<int>((double)pts_green[i].x / frame1.cols * 12) + 1, 1, 12);
                    int string_num = std::clamp(static_cast<int>((double)pts_green[i].y / frame1.rows * 6) + 1, 1, 6);

                    data->fingers[i].x = pts_green[i].x;
                    data->fingers[i].y = pts_green[i].y;
                    data->fingers[i].key_index = fret;
                    data->fingers[i].string_index = string_num;

                    cv::circle(frame1, pts_green[i], 8, cv::Scalar(0, 255, 0), -1);
                    cv::putText(frame1, std::to_string(string_num) + "S-" + std::to_string(fret) + "F",
                                cv::Point(pts_green[i].x + 10, pts_green[i].y - 10),
                                cv::FONT_HERSHEY_SIMPLEX, 0.4, cv::Scalar(0, 255, 0), 1);
                }
            } else {
                g_base_left_y = -1;
            }

            if (g_current_play_style == 1) {
                for (const auto& guide : g_active_guides) {
                    int target_x = static_cast<int>((double)(guide.key_index - 0.5) / 12.0 * frame1.cols);
                    int target_y = static_cast<int>((double)(guide.string_index - 0.5) / 6.0 * frame1.rows);

                    int ring_radius = std::clamp(static_cast<int>(15 + guide.time_diff * 40), 15, 80);
                    cv::circle(frame1, cv::Point(target_x, target_y), ring_radius, cv::Scalar(0, 255, 255), 2);
                    cv::circle(frame1, cv::Point(target_x, target_y), 12, cv::Scalar(255, 0, 255), -1);
                }

                cv::putText(frame1, "SCORE: " + std::to_string(data->score), cv::Point(20, 40), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(255, 255, 255), 2);
                cv::putText(frame1, "COMBO: " + std::to_string(data->combo), cv::Point(20, 80), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(0, 255, 255), 2);
            } else {
                cv::putText(frame1, "[FREE GUITAR MODE]", cv::Point(20, 40), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(0, 255, 0), 2);
            }

            cv::imshow("Guitar - Right Strum (Cam 0)", frame0);
            cv::imshow("Guitar - Left Fret (Cam 1)", frame1);
        } else {
            cv::imshow("Air Musician - Guitar Main (Cam 0)", frame0);
        }
    }

    cv::waitKey(1);
}

DLLEXPORT void cleanup_tracker() {
    if (g_cap0) { g_cap0->release(); delete g_cap0; g_cap0 = nullptr; }
    if (g_cap1) { g_cap1->release(); delete g_cap1; g_cap1 = nullptr; }
    cv::destroyAllWindows();
}

} // extern "C"
