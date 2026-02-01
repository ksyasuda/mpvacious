--[[
Copyright: Ajatt-Tools and contributors; https://github.com/Ajatt-Tools

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Requirements:
* mpv >= 0.32.0
* AnkiConnect
* curl
* xclip (when running X11)
* wl-copy (when running Wayland)

Usage:
1. Change `config` according to your needs
* Config path: ~/.config/mpv/script-opts/subs2srs.conf
* Config file isn't created automatically.

2. Open a video

3. Use key bindings to manipulate the script
* Open mpvacious menu - `a`
* Create a note from the current subtitle line - `Ctrl + n`

For complete usage guide, see <https://github.com/Ajatt-Tools/mpvacious/blob/master/README.md>
]]

local mp = require('mp')
local OSD = require('osd_styler')
local make_cfg_mgr = require('config.cfg_mgr')
local encoder = require('encoder.encoder')
local h = require('helpers')
local Menu = require('menu')
local ankiconnect = require('anki.ankiconnect')
local switch = require('utils.switch')
local play_control = require('utils.play_control')
local secondary_sid = require('subtitles.secondary_sid')
local platform = require('platform.init')
local forvo = require('utils.forvo')
local subs_observer = require('subtitles.observer')
local codec_support = require('encoder.codec_support')
local make_new_note_checker = require('anki.new_note_checker')
local make_note_exporter = require('anki.note_exporter')

local menu, quick_menu, quick_menu_card
local quick_creation_opts = {
    _n_lines = nil,
    _n_cards = 1,
    set_cards = function(self, n)
        self._n_cards = math.max(0, n)
    end,
    set_lines = function(self, n)
        self._n_lines = math.max(0, n)
    end,
    get_cards = function(self)
        return self._n_cards
    end,
    get_lines = function(self)
        return self._n_lines
    end,
    increment_cards = function(self)
        self:set_cards(self._n_cards + 1)
    end,
    decrement_cards = function(self)
        self:set_cards(self._n_cards - 1)
    end,
    clear_options = function(self)
        self._n_lines = nil
        self._n_cards = 1
    end,
}
------------------------------------------------------------
-- utility functions
local new_note_checker = make_new_note_checker.new()
local note_exporter = make_note_exporter.new()
local cfg_mgr = make_cfg_mgr.new()

local function _(params)
    return function()
        local status, err = pcall(h.unpack(params))
        if not status then
            h.notify(err, "error", 5)
        end
    end
end

local function escape_for_osd(str)
    str = h.trim(str)
    str = str:gsub("[%[%]{}]", "")
    return str
end

local function ensure_deck()
    if cfg_mgr.config().create_deck == true then
        ankiconnect.create_deck(cfg_mgr.config().deck_name)
    end
end

local function load_next_profile()
    cfg_mgr.next_profile()
    ensure_deck()
<<<<<<< HEAD
    h.notify("Loaded profile " .. cfg_mgr.profiles().active)
=======
    h.notify("Loaded profile " .. profiles.active)
end

local function tag_format(filename)
    filename = h.remove_extension(filename)
    filename = h.remove_common_resolutions(filename)

    local s, e, episode_num = h.get_episode_number(filename)

    if config.tag_del_episode_num == true and not h.is_empty(s) then
        if config.tag_del_after_episode_num == true then
            -- Removing everything (e.g. episode name) after the episode number including itself.
            filename = filename:sub(1, s)
        else
            -- Removing the first found instance of the episode number.
            filename = filename:sub(1, s) .. filename:sub(e + 1, -1)
        end
    end

    if config.tag_nuke_brackets == true then
        filename = h.remove_text_in_brackets(filename)
    end
    if config.tag_nuke_parentheses == true then
        filename = h.remove_filename_text_in_parentheses(filename)
    end

    if config.tag_filename_lowercase == true then
        filename = filename:lower()
    end

    filename = h.remove_leading_trailing_spaces(filename)
    filename = filename:gsub(" ", "_")
    filename = filename:gsub("_%-_", "_") -- Replaces garbage _-_ substrings with a underscore
    filename = h.remove_leading_trailing_dashes(filename)
    return filename, episode_num or ""
end

local substitute_fmt = (function()
    local function substitute_filename(tag, filename)
        return tag:gsub("%%n", filename)
    end

    local function substitute_episode_number(tag, episode)
        return tag:gsub("%%d", episode)
    end

    local function substitute_time_pos(tag)
        local time_pos = h.human_readable_time(mp.get_property_number("time-pos"))
        return tag:gsub("%%t", time_pos)
    end

    local function substitute_envvar(tag)
        local env_tags = os.getenv("SUBS2SRS_TAGS") or ""
        return tag:gsub("%%e", env_tags)
    end

    return function(tag)
        if not h.is_empty(tag) then
            local filename, episode = tag_format(mp.get_property("filename"))
            tag = substitute_filename(tag, filename)
            tag = substitute_episode_number(tag, episode)
            tag = substitute_time_pos(tag)
            tag = substitute_envvar(tag)
            tag = h.remove_leading_trailing_spaces(tag)
        end
        return tag
    end
end)()

local function prepare_for_exporting(sub_text)
    if not h.is_empty(sub_text) then
        sub_text = h.trim(sub_text)
        sub_text = h.escape_special_characters(sub_text)
    end
    return sub_text
end

local function construct_note_fields(sub_text, secondary_text, snapshot_filename, audio_filename)
    local ret = {
        [config.sentence_field] = subs_observer.maybe_remove_all_spaces(prepare_for_exporting(sub_text)),
        ["IsSentenceCard"] = "x",
    }
    -- Add Sentence field if there's content in the sentence_field
    if not h.is_empty(ret[config.sentence_field]) and not config.sentence_field == "Sentence" then
        ret["Sentence"] = ret[config.sentence_field]
    end
    if not h.is_empty(config.secondary_field) then
        ret[config.secondary_field] = prepare_for_exporting(secondary_text)
    end
    if not h.is_empty(config.image_field) and not h.is_empty(snapshot_filename) then
        ret[config.image_field] = string.format(config.image_template, snapshot_filename)
    end
    if not h.is_empty(config.audio_field) and not h.is_empty(audio_filename) then
        ret[config.audio_field] = string.format(config.audio_template, audio_filename)
    end
    if config.miscinfo_enable == true then
        ret[config.miscinfo_field] = substitute_fmt(config.miscinfo_format)
    end
    return ret
end

local function join_field_content(new_text, old_text, separator)
    -- By default, join fields with a HTML newline.
    separator = separator or "<br>"

    if h.is_empty(old_text) then
        -- If 'old_text' is empty, there's no need to join content with the separator.
        return new_text
    end

    if h.is_substr(old_text, new_text) then
        -- If 'old_text' (field) already contains new_text (sentence, image, audio, etc.),
        -- there's no need to add 'new_text' to 'old_text'.
        return old_text
    end

    return string.format("%s%s%s", old_text, separator, new_text)
end

local function join_fields(new_data, stored_data)
    for _, field in pairs({
        config.audio_field,
        config.image_field,
        config.miscinfo_field,
        config.sentence_field,
        config.secondary_field,
    }) do
        if not h.is_empty(field) then
            new_data[field] = join_field_content(h.table_get(new_data, field, ""), h.table_get(stored_data, field, ""))
        end
    end
    return new_data
end

local function update_sentence(new_data, stored_data)
    -- adds support for TSCs
    -- https://tatsumoto-ren.github.io/blog/discussing-various-card-templates.html#targeted-sentence-cards-or-mpvacious-cards
    -- if the target word was marked by yomichan, this function makes sure that the highlighting doesn't get erased.

    if h.is_empty(stored_data[config.sentence_field]) then
        -- sentence field is empty. can't continue.
        return new_data
    elseif h.is_empty(new_data[config.sentence_field]) then
        -- *new* sentence field is empty, but old one contains data. don't delete the existing sentence.
        new_data[config.sentence_field] = stored_data[config.sentence_field]
        return new_data
    end

    local _, opentag, target, closetag, _ =
        stored_data[config.sentence_field]:match("^(.-)(<[^>]+>)(.-)(</[^>]+>)(.-)$")
    if target then
        local prefix, _, suffix = new_data[config.sentence_field]:match(table.concat({ "^(.-)(", target, ")(.-)$" }))
        if prefix and suffix then
            new_data[config.sentence_field] = table.concat({ prefix, opentag, target, closetag, suffix })
        end
    end
    return new_data
end

local function audio_padding()
    local video_duration = mp.get_property_number("duration")
    if config.audio_padding == 0.0 or not video_duration then
        return 0.0
    end
    if subs_observer.user_altered() then
        return 0.0
    end
    return config.audio_padding
end

------------------------------------------------------------
-- front for adding and updating notes

local function maybe_reload_config()
    if config.reload_config_before_card_creation then
        cfg_mgr.reload_from_disk()
    end
end

local function get_anki_media_dir_path()
    return ankiconnect.get_media_dir_path()
end

local function export_to_anki(gui)
    maybe_reload_config()
    local sub = subs_observer.collect_from_current()

    if not sub:is_valid() then
        return h.notify("Nothing to export.", "warn", 1)
    end

    if not gui and h.is_empty(sub["text"]) then
        sub["text"] = string.format("mpvacious wasn't able to grab subtitles (%s)", os.time())
    end

    encoder.set_output_dir(get_anki_media_dir_path())
    local snapshot = encoder.snapshot.create_job(sub)
    local audio = encoder.audio.create_job(sub, audio_padding())

    snapshot.run_async()
    audio.run_async()

    local first_field = ankiconnect.get_first_field(config.model_name)
    local note_fields = construct_note_fields(sub["text"], sub["secondary"], snapshot.filename, audio.filename)

    if not h.is_empty(first_field) and h.is_empty(note_fields[first_field]) then
        note_fields[first_field] = "[empty]"
    end

    ankiconnect.add_note(note_fields, substitute_fmt(config.note_tag), gui)
    subs_observer.clear()
end

local function notify_user_on_finish(note_ids)
    --- Run this callback once all notes are changed.

    -- Construct a search query for the Anki Browser.
    local queries = {}
    for _, note_id in ipairs(note_ids) do
        table.insert(queries, string.format("nid:%s", tostring(note_id)))
    end
    local query = table.concat(queries, " OR ")
    ankiconnect.gui_browse(query)

    -- Notify the user.
    if #note_ids > 1 then
        h.notify(string.format("Updated %i notes.", #note_ids))
    else
        h.notify(string.format("Updated note #%s.", tostring(note_ids[1])))
    end
end

local function change_fields(note_ids, new_data, overwrite)
    --- Run this callback once audio and image files are created.

    local change_notes_countdown = dec_counter.new(#note_ids).on_finish(h.as_callback(notify_user_on_finish, note_ids))

    for _, note_id in pairs(note_ids) do
        local stored_data = ankiconnect.get_note_fields(note_id)
        if stored_data then
            new_data = forvo.append(new_data, stored_data)
            new_data = update_sentence(new_data, stored_data)
            if not overwrite then
                if config.append_media then
                    new_data = join_fields(new_data, stored_data)
                else
                    new_data = join_fields(stored_data, new_data)
                end
            end
        end

        -- If the text is still empty, put some dummy text to let the user know why
        -- there's no text in the sentence field.
        if h.is_empty(new_data[config.sentence_field]) then
            new_data[config.sentence_field] = string.format("mpvacious wasn't able to grab subtitles (%s)", os.time())
        end

        ankiconnect.append_media(note_id, new_data, substitute_fmt(config.note_tag), change_notes_countdown.decrease)
    end
end

local function update_notes(note_ids, overwrite)
    local sub
    local n_lines = quick_creation_opts:get_lines()
    if n_lines then
        sub = subs_observer.collect_from_all_dialogues(n_lines)
    else
        sub = subs_observer.collect_from_current()
    end

    if not sub:is_valid() then
        return h.notify("Nothing to export. Have you set the timings?", "warn", 2)
    end

    if h.is_empty(sub["text"]) then
        -- In this case, don't modify whatever existing text there is and just
        -- modify the other fields we can. The user might be trying to add
        -- audio to a card which they've manually transcribed (either the video
        -- has no subtitles or it has image subtitles).
        sub["text"] = nil
    end

    local anki_media_dir = get_anki_media_dir_path()
    encoder.set_output_dir(anki_media_dir)
    forvo.set_output_dir(anki_media_dir)

    local snapshot = encoder.snapshot.create_job(sub)
    local audio = encoder.audio.create_job(sub, audio_padding())
    local new_data = construct_note_fields(sub["text"], sub["secondary"], snapshot.filename, audio.filename)
    local create_files_countdown =
        dec_counter.new(2).on_finish(h.as_callback(change_fields, note_ids, new_data, overwrite))

    snapshot.on_finish(create_files_countdown.decrease).run_async()
    audio.on_finish(create_files_countdown.decrease).run_async()

    subs_observer.clear()
    quick_creation_opts:clear_options()
end

local function update_last_note(overwrite)
    maybe_reload_config()

    local n_cards = quick_creation_opts:get_cards()
    -- this now returns a table
    local last_note_ids = ankiconnect.get_last_note_ids(n_cards)
    n_cards = #last_note_ids

    --first element is the earliest
    if h.is_empty(last_note_ids) or last_note_ids[1] < h.minutes_ago(10) then
        return h.notify("Couldn't find the target note.", "warn", 2)
    end

    update_notes(last_note_ids, overwrite)
end

local function update_selected_note(overwrite)
    maybe_reload_config()

    local selected_note_ids = ankiconnect.get_selected_note_ids()

    if h.is_empty(selected_note_ids) then
        return h.notify("Couldn't find the target note(s). Did you select the notes you want in Anki?", "warn", 3)
    end

    if #selected_note_ids > config.card_overwrite_safeguard then
        return h.notify(
            string.format(
                "More than %i notes selected\nnot recommended, but you can change the limit in your config",
                config.card_overwrite_safeguard
            ),
            "warn",
            4
        )
    end

    update_notes(selected_note_ids, overwrite)
>>>>>>> eb9165f (update Sentence field logic)
end

------------------------------------------------------------
-- main menu

menu = Menu:new({
    hints_state = switch.new({ "basic", "menu", "global", "hidden" }),
})

menu.keybindings = {
    { key = 'S', fn = menu:with_update { subs_observer.set_manual_timing_to_sub, 'start' } },
    { key = 'E', fn = menu:with_update { subs_observer.set_manual_timing_to_sub, 'end' } },
    { key = 's', fn = menu:with_update { subs_observer.set_manual_timing, 'start' } },
    { key = 'e', fn = menu:with_update { subs_observer.set_manual_timing, 'end' } },
    { key = 'c', fn = menu:with_update { subs_observer.set_to_current_sub } },
    { key = 'r', fn = menu:with_update { subs_observer.clear_and_notify } },
    { key = 'g', fn = menu:with_update { note_exporter.export_to_anki, true } },
    { key = 'n', fn = menu:with_update { note_exporter.export_to_anki, false } },
    { key = 'b', fn = menu:with_update { note_exporter.update_selected_note, false } },
    { key = 'B', fn = menu:with_update { note_exporter.update_selected_note, true } },
    { key = 'm', fn = menu:with_update { note_exporter.update_last_note, false } },
    { key = 'M', fn = menu:with_update { note_exporter.update_last_note, true } },
    { key = 'f', fn = menu:with_update { quick_creation_opts.increment_cards, quick_creation_opts } },
    { key = 'F', fn = menu:with_update { quick_creation_opts.decrement_cards, quick_creation_opts } },
    { key = 't', fn = menu:with_update { subs_observer.toggle_autocopy } },
    { key = 'T', fn = menu:with_update { subs_observer.next_autoclip_method } },
    { key = 'i', fn = menu:with_update { menu.hints_state.bump } },
    { key = 'p', fn = menu:with_update { load_next_profile } },
    { key = 'ESC', fn = _ { menu.close, menu } },
    { key = 'q', fn = _ { menu.close, menu } },
}

function menu:print_header(osd)
    if self.hints_state.get() == "hidden" then
        return
    end
    osd:submenu('mpvacious options'):newline()
    osd:item('Timings: '):text(h.human_readable_time(subs_observer.get_timing('start')))
    osd:item(' to '):text(h.human_readable_time(subs_observer.get_timing('end'))):newline()
    osd:item('Clipboard autocopy: '):text(subs_observer.autocopy_status_str()):newline()
    osd:item('Active profile: '):text(cfg_mgr.profiles().active):newline()
    osd:item('Deck: '):text(cfg_mgr.config().deck_name):newline()
    osd:item('# cards: '):text(quick_creation_opts:get_cards()):newline()
end

function menu:print_bindings(osd)
    if self.hints_state.get() == "global" then
        osd:submenu("Global bindings"):newline()
        osd:tab():item("ctrl+c: "):text("Copy current subtitle to clipboard"):newline()
        osd:tab():item("ctrl+h: "):text("Seek to the start of the line"):newline()
        osd:tab():item("ctrl+g: "):text("Toggle animated snapshots"):newline()
        osd:tab():item("ctrl+shift+h: "):text("Replay current subtitle"):newline()
        osd:tab():item("shift+h/l: "):text("Seek to the previous/next subtitle"):newline()
        osd:tab():item("alt+h/l: "):text("Seek to the previous/next subtitle and pause"):newline()
        osd:italics("Press "):item("i"):italics(" to hide mpvacious options."):newline()
    elseif self.hints_state.get() == "menu" then
        osd:submenu("Menu bindings"):newline()
        osd:tab():item("c: "):text("Set timings to the current sub"):newline()
        osd:tab():item("s: "):text("Set start time to current position"):newline()
        osd:tab():item("e: "):text("Set end time to current position"):newline()
        osd:tab():item("shift+s: "):text("Set start time to current subtitle"):newline()
        osd:tab():item("shift+e: "):text("Set end time to current subtitle"):newline()
        osd:tab():item("f: "):text("Increment # cards to update "):italics("(+shift to decrement)"):newline()
        osd:tab():item("r: "):text("Reset timings"):newline()
        osd:tab():item("n: "):text("Export note"):newline()
        osd:tab():item("g: "):text("GUI export"):newline()
        osd:tab():item("b: "):text("Update the selected note"):italics("(+shift to overwrite)"):newline()
        osd:tab():item("m: "):text("Update the last added note "):italics("(+shift to overwrite)"):newline()
        osd:tab():item("t: "):text("Toggle clipboard autocopy"):newline()
        osd:tab():item("T: "):text("Switch to the next clipboard method"):newline()
        osd:tab():item("p: "):text("Switch to next profile"):newline()
        osd:tab():item("ESC: "):text("Close"):newline()
        osd:italics("Press "):item("i"):italics(" to show global bindings."):newline()
    elseif self.hints_state.get() == "hidden" then
        -- Menu bindings are active but hidden
    else
        osd:italics("Press "):item("i"):italics(" to show menu bindings."):newline()
    end
end

function menu:warn_formats(osd)
    if cfg_mgr.config().use_ffmpeg then
        return
    end
    for type, codecs in pairs(codec_support) do
        for codec, supported in pairs(codecs) do
            if not supported and cfg_mgr.config()[type .. '_codec'] == codec then
                osd:red('warning: '):newline()
                osd:tab():text(string.format("your version of mpv does not support %s.", codec)):newline()
                osd:tab():text(string.format("mpvacious won't be able to create %s files.", type)):newline()
            end
        end
    end
end

function menu:warn_clipboard(osd)
    if subs_observer.autocopy_current_method() == "clipboard" and platform.healthy == false then
        osd:red("warning: "):text(string.format("%s is not installed.", platform.clip_util)):newline()
    end
end

function menu:print_legend(osd)
    osd:new_layer():size(cfg_mgr.config().menu_font_size):font(cfg_mgr.config().menu_font_name):align(4)
    self:print_header(osd)
    self:print_bindings(osd)
    self:warn_formats(osd)
    self:warn_clipboard(osd)
end

function menu:print_selection(osd)
    if subs_observer.is_appending() and cfg_mgr.config().show_selected_text then
        osd:new_layer():size(cfg_mgr.config().menu_font_size):font(cfg_mgr.config().menu_font_name):align(6)
        osd:submenu("Primary text"):newline()
        for _, s in ipairs(subs_observer.recorded_subs()) do
            osd:text(escape_for_osd(s["text"])):newline()
        end
        if not h.is_empty(cfg_mgr.config().secondary_field) then
            -- If the user wants to add secondary subs to Anki,
            -- it's okay to print them on the screen.
            osd:submenu("Secondary text"):newline()
            for _, s in ipairs(subs_observer.recorded_secondary_subs()) do
                osd:text(escape_for_osd(s["text"])):newline()
            end
        end
    end
end

function menu:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    self:print_selection(osd)
    return osd
end

------------------------------------------------------------
-- quick_menu line selection

local choose_cards = function(i)
    quick_creation_opts:set_cards(i)
    quick_menu_card:close()
    quick_menu:open()
end
local choose_lines = function(i)
    quick_creation_opts:set_lines(i)
    note_exporter.update_last_note(true)
    quick_menu:close()
end

quick_menu = Menu:new()
quick_menu.keybindings = {}
for i = 1, 9 do
    table.insert(quick_menu.keybindings, {
        key = tostring(i),
        fn = function()
            choose_lines(i)
        end,
    })
end
table.insert(quick_menu.keybindings, {
    key = "ctrl+y",
    fn = function()
        choose_lines(1)
    end,
})
table.insert(quick_menu.keybindings, {
    key = "ESC",
    fn = function()
        quick_menu:close()
    end,
})
table.insert(quick_menu.keybindings, {
    key = "q",
    fn = function()
        quick_menu:close()
    end,
})
function quick_menu:print_header(osd)
    osd:submenu("quick card creation: line selection"):newline()
    osd:item("# lines: "):text("Enter 1-9"):newline()
end

function quick_menu:print_legend(osd)
    osd:new_layer():size(cfg_mgr.config().menu_font_size):font(cfg_mgr.config().menu_font_name):align(4)
    self:print_header(osd)
    menu:warn_formats(osd)
end

function quick_menu:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    return osd
end

-- quick_menu card selection
quick_menu_card = Menu:new()
quick_menu_card.keybindings = {}
for i = 1, 9 do
    table.insert(quick_menu_card.keybindings, {
        key = tostring(i),
        fn = function()
            choose_cards(i)
        end,
    })
end
table.insert(quick_menu_card.keybindings, { key = 'ESC', fn = _ { quick_menu_card.close, quick_menu_card } })
table.insert(quick_menu_card.keybindings, { key = 'q', fn = _ { quick_menu_card.close, quick_menu_card } })
function quick_menu_card:print_header(osd)
    osd:submenu("quick card creation: card selection"):newline()
    osd:item("# cards: "):text("Enter 1-9"):newline()
end

function quick_menu_card:print_legend(osd)
    osd:new_layer():size(cfg_mgr.config().menu_font_size):font(cfg_mgr.config().menu_font_name):align(4)
    self:print_header(osd)
    menu:warn_formats(osd)
end

function quick_menu_card:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    return osd
end

------------------------------------------------------------
-- tests

local function run_tests()
    h.run_tests()
    local new_note = {
        SentKanji = "それは…分からんよ",
        SentAudio = "[sound:s01e13_02m25s010ms_02m27s640ms.ogg]",
        SentEng = "Well...",
        Image = '<img alt="snapshot" src="s01e13_02m25s561ms.avif">',
    }
    local old_note = {
        SentAudio = "[sound:s01e13_02m21s340ms_02m24s140ms.ogg]",
        Image = '<img alt="snapshot" src="s01e13_02m22s225ms.avif">',
        VocabAudio = "",
        Notes = "",
        VocabDef = "",
        SentKanji = "勝ちって何に？",
        SentEng = "What would we win, exactly?",
    }
    local result = note_exporter.join_fields(new_note, old_note)
    local expected = {
        SentKanji = "勝ちって何に？<br>それは…分からんよ",
        SentAudio = "[sound:s01e13_02m21s340ms_02m24s140ms.ogg]<br>[sound:s01e13_02m25s010ms_02m27s640ms.ogg]",
        SentEng = "What would we win, exactly?<br>Well...",
        Image = '<img alt="snapshot" src="s01e13_02m22s225ms.avif"><br><img alt="snapshot" src="s01e13_02m25s561ms.avif">',
        Notes = "",
    }
    h.assert_equals(result, expected)
end

local function pcall_tests()
    if os.getenv("MPVACIOUS_TEST") == "TRUE" then
        -- at this point, other tests in submodules should have been finished.
        mp.msg.warn("RUNNING TESTS")
        local success, err = pcall(run_tests)
        if not success then
            mp.msg.error("TESTS FAILED")
            mp.msg.error(err)
        else
            mp.msg.warn("TESTS PASSED")
        end
        mp.commandv("quit")
    end
end

------------------------------------------------------------
-- main

local main = (function()
    local main_executed = false
    return function()
        if main_executed then
            subs_observer.clear_all_dialogs()
            return
        else
            main_executed = true
        end
        cfg_mgr.init()
        ankiconnect.init(cfg_mgr)
        forvo.init(cfg_mgr)
        encoder.init(cfg_mgr)
        secondary_sid.init(cfg_mgr)
        ensure_deck()
        subs_observer.init(menu, cfg_mgr)
        note_exporter.init(ankiconnect, quick_creation_opts, subs_observer, encoder, forvo, cfg_mgr)
        new_note_checker.init(ankiconnect, menu:with_update { note_exporter.update_notes }, cfg_mgr)
        pcall_tests()

        -- Key bindings
        mp.add_forced_key_binding(
            "Ctrl+c",
            "mpvacious-copy-sub-to-clipboard",
            subs_observer.copy_current_primary_to_clipboard
        )
        mp.add_key_binding(
            "Ctrl+C",
            "mpvacious-copy-secondary-sub-to-clipboard",
            subs_observer.copy_current_secondary_to_clipboard
        )
        mp.add_key_binding("Ctrl+t", "mpvacious-autocopy-toggle", subs_observer.toggle_autocopy)
        mp.add_key_binding("Ctrl+g", "mpvacious-animated-snapshot-toggle", encoder.snapshot.toggle_animation)

        -- Secondary subtitles
        mp.add_key_binding("Ctrl+V", "mpvacious-secondary-sid-toggle", secondary_sid.change_visibility)
        mp.add_key_binding("Ctrl+k", "mpvacious-secondary-sid-prev", secondary_sid.select_previous)
        mp.add_key_binding("Ctrl+j", "mpvacious-secondary-sid-next", secondary_sid.select_next)

        -- Open advanced menu
        mp.add_key_binding("a", "mpvacious-menu-open", _ { menu.open, menu })

        -- Add note
        mp.add_forced_key_binding("Ctrl+n", "mpvacious-export-note", menu:with_update { note_exporter.export_to_anki, false })

        -- Note updating
        mp.add_key_binding("Ctrl+b", "mpvacious-update-selected-note", menu:with_update { note_exporter.update_selected_note, false })
        mp.add_key_binding("Ctrl+B", "mpvacious-overwrite-selected-note", menu:with_update { note_exporter.update_selected_note, true })
        mp.add_key_binding("Ctrl+m", "mpvacious-update-last-note", menu:with_update { note_exporter.update_last_note, false })
        mp.add_key_binding("Ctrl+M", "mpvacious-overwrite-last-note", menu:with_update { note_exporter.update_last_note, true })

        mp.add_key_binding("g", "mpvacious-quick-card-menu-open", _ { quick_menu.open, quick_menu })
        mp.add_key_binding("Alt+g", "mpvacious-quick-card-sel-menu-open", _ { quick_menu_card.open, quick_menu_card })

        -- Vim-like seeking between subtitle lines
        mp.add_key_binding("H", "mpvacious-sub-seek-back", _({ play_control.sub_seek, "backward" }))
        mp.add_key_binding("L", "mpvacious-sub-seek-forward", _({ play_control.sub_seek, "forward" }))

        mp.add_key_binding("Alt+h", "mpvacious-sub-seek-back-pause", _({ play_control.sub_seek, "backward", true }))
        mp.add_key_binding("Alt+l", "mpvacious-sub-seek-forward-pause", _({ play_control.sub_seek, "forward", true }))

        mp.add_key_binding("Ctrl+h", "mpvacious-sub-rewind", _({ play_control.sub_rewind }))
        mp.add_key_binding("Ctrl+H", "mpvacious-sub-replay", _({ play_control.play_till_sub_end }))
        mp.add_key_binding("Ctrl+L", "mpvacious-sub-play-up-to-next", _({ play_control.play_till_next_sub_end }))

        mp.msg.warn("Press 'a' to open the mpvacious menu.")

        -- start timer
        new_note_checker.start_timer()
    end
end)()

mp.register_event("file-loaded", main)
