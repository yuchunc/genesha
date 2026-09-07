defmodule GaneshaWeb.CoreComponents do
  @moduledoc """
  The studio ledger's component vocabulary.

  Two groups. Form and feedback primitives (`input/1`, `button/1`, `flash/1`)
  restyled onto the design tokens, and the ledger devices that carry meaning:

    * `seal/1` — the weekday stamp that identifies a recurring class
    * `pill/1` — how a place on a roster was paid for
    * `money/1` — a figure and its label on one baseline, tabular
    * `section/1` — a ruled heading, the only structure most screens need
    * `empty/1` — an empty state written as an invitation

  Each device encodes something. See
  `docs/superpowers/specs/2026-09-06-ui-design-system.md` for why there are no
  four-sided cards, no numbered markers outside the signup list, and no icons
  outside the bottom navigation.
  """
  use Phoenix.Component
  use Gettext, backend: GaneshaWeb.Gettext

  alias GaneshaWeb.Fmt
  alias Phoenix.LiveView.JS

  # Outline tone: a hairline and a matching ink. The filled variants live in
  # `seal/1`, which is the only device that ever reverses out.
  defp outline_tone("ink"), do: "border-ink text-ink"
  defp outline_tone("quiet"), do: "border-rule text-ink-faint"
  defp outline_tone("turmeric"), do: "border-turmeric text-turmeric-ink"
  defp outline_tone("sindoor"), do: "border-sindoor text-sindoor-ink"
  defp outline_tone("celadon"), do: "border-celadon text-celadon-ink"

  defp filled_tone("ink"), do: "border-ink bg-ink text-paper"
  defp filled_tone("quiet"), do: "border-rule-strong bg-rule-strong text-paper"
  defp filled_tone("turmeric"), do: "border-turmeric bg-turmeric text-paper"
  defp filled_tone("sindoor"), do: "border-sindoor bg-sindoor text-paper"
  defp filled_tone("celadon"), do: "border-celadon bg-celadon text-paper"

  defp seal_size("sm"), do: "size-7 text-sm"
  defp seal_size("md"), do: "size-10 text-lg"
  defp seal_size("lg"), do: "size-14 text-xl"

  @doc """
  The weekday stamp for a recurring class.

  A 印章 is the mark of authority in a hand-kept ledger. Here it answers "which
  class" before a word is read. Two classes on the same weekday share a glyph
  and are told apart by the time beside it, which is true to the domain.

  ## Examples

      <.seal weekday={1} />
      <.seal weekday={3} tone="sindoor" filled />
  """
  attr :weekday, :any, required: true, doc: "1..7, or a Date"
  attr :tone, :string, default: "ink", values: ~w(ink quiet turmeric sindoor celadon)
  attr :filled, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  def seal(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-flex shrink-0 items-center justify-center border-[1.5px] font-display leading-none",
        seal_size(@size),
        if(@filled, do: filled_tone(@tone), else: outline_tone(@tone)),
        @class
      ]}
    >
      {Fmt.weekday_glyph(@weekday)}
    </span>
    """
  end

  @doc """
  How a place on a roster was paid for, or what state a record is in.

  ## Examples

      <.pill tone="celadon">已確認</.pill>
      <.pill tone="turmeric">補課</.pill>
  """
  attr :tone, :string, default: "quiet", values: ~w(ink quiet turmeric sindoor celadon)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs whitespace-nowrap",
      outline_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A money figure with its label on the same baseline.

  Integer TWD only, thousands-separated, tabular so columns of figures line up.
  The label follows the figure rather than sitting above it: a ledger line, not
  a statistic in a box.

  ## Examples

      <.money amount={18_400} label="本月已確認" size="xl" />
      <.money amount={1200} tone="turmeric" />
  """
  attr :amount, :integer, required: true
  attr :label, :string, default: nil
  attr :size, :string, default: "md", values: ~w(sm md lg xl)
  attr :tone, :string, default: "ink", values: ~w(ink soft turmeric sindoor celadon)
  attr :prefix, :string, default: "NT$"
  attr :class, :any, default: nil
  attr :rest, :global

  def money(assigns) do
    sizes = %{
      "sm" => "text-sm",
      "md" => "text-lg",
      "lg" => "text-xl",
      "xl" => "text-3xl"
    }

    colors = %{
      "ink" => "text-ink",
      "soft" => "text-ink-soft",
      "turmeric" => "text-turmeric-ink",
      "sindoor" => "text-sindoor-ink",
      "celadon" => "text-celadon-ink"
    }

    assigns = assign(assigns, sizes: sizes, colors: colors)

    ~H"""
    <span class={["inline-flex items-baseline gap-2", @class]} {@rest}>
      <span class={[
        "font-display tabular-nums",
        Map.fetch!(@sizes, @size),
        Map.fetch!(@colors, @tone)
      ]}>
        <span class="text-[0.7em] font-light">{@prefix}</span>{Fmt.amount(@amount)}
      </span>
      <span :if={@label} class="text-xs text-ink-faint">{@label}</span>
    </span>
    """
  end

  @doc """
  A screen's title.

  ## Examples

      <.page_header title="收款">
        <:subtitle>2026年9月</:subtitle>
        <:actions><.button navigate={~p"/publish"}>發布課表</.button></:actions>
      </.page_header>
  """
  attr :title, :string, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="mb-6 flex items-end justify-between gap-4">
      <div>
        <h1 class="font-display text-2xl leading-tight text-ink">{@title}</h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-soft">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A ruled section heading. The rule is the structure; there is no card.

  ## Examples

      <.section title="未收款" count={3}>
        …rows…
      </.section>
  """
  attr :title, :string, required: true
  attr :count, :any, default: nil, doc: "an integer shown beside the title"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={["mt-8", @class]} {@rest}>
      <div class="flex items-center gap-3 border-b border-rule pb-2">
        <h2 class="text-sm font-medium text-ink">{@title}</h2>
        <span :if={@count} class="font-display text-sm tabular-nums text-ink-faint">
          {@count}
        </span>
        <div :if={@actions != []} class="ml-auto flex items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  An empty state, written as an invitation to act rather than a shrug.

  ## Examples

      <.empty id="no-enrollments">
        本月還沒有人報名。
        <:action><.button phx-click="generate">建立本月課程</.button></:action>
      </.empty>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :action

  def empty(assigns) do
    ~H"""
    <div id={@id} class={["border-l-[3px] border-rule py-3 pl-4", @class]}>
      <p class="text-sm text-ink-soft">{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="mt-3">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  Anchored to the bottom on a phone, above the navigation bar, so the message
  lands within thumb reach of the hand that caused it.

  ## Examples

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed inset-x-4 bottom-[calc(72px+env(safe-area-inset-bottom))] z-50 sm:inset-x-auto sm:right-6 sm:bottom-6 sm:w-96"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 border-l-[3px] px-4 py-3 text-sm text-wrap shadow-[0_2px_16px_rgba(22,35,63,0.14)]",
        @kind == :info && "border-celadon bg-celadon-lift text-ink",
        @kind == :error && "border-sindoor bg-sindoor-lift text-ink"
      ]}>
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-medium">{@title}</p>
          <p>{msg}</p>
        </div>
        <button
          type="button"
          class="shrink-0 cursor-pointer text-ink-faint hover:text-ink"
          aria-label={gettext("關閉")}
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  Variants say what the button does, not how loud it is: `primary` commits a
  record, `accent` moves money, `danger` cancels a class, the default is
  everything else.

  ## Examples

      <.button variant="primary" phx-click="save">建立本月課程</.button>
      <.button navigate={~p"/"}>回到總覽</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any
  attr :variant, :string, default: nil, values: [nil, "primary", "accent", "danger", "quiet"]
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "border-ink bg-ink text-paper hover:bg-ink-soft hover:border-ink-soft",
      "accent" => "border-turmeric bg-turmeric text-paper hover:brightness-110",
      "danger" => "border-sindoor bg-transparent text-sindoor-ink hover:bg-sindoor-lift",
      "quiet" => "border-transparent bg-transparent text-ink-soft hover:text-ink",
      nil => "border-rule-strong bg-transparent text-ink hover:bg-sunk"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        [
          "inline-flex min-h-11 cursor-pointer items-center justify-center gap-2 border px-4 py-2 text-sm transition-colors disabled:cursor-not-allowed disabled:opacity-40",
          Map.fetch!(variants, assigns[:variant])
        ]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="space-y-1">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="flex min-h-11 cursor-pointer items-center gap-3 text-sm text-ink">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "size-5 shrink-0 rounded-none accent-[var(--c-turmeric)]"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-xs text-ink-soft">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || control_class(@errors, @error_class)]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-xs text-ink-soft">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[@class || control_class(@errors, @error_class)]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-xs text-ink-soft">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[@class || control_class(@errors, @error_class)]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Inputs are sunk into the paper rather than raised off it, and figures typed
  # into them are set in the display face so an amount reads the same in the
  # field as it will in the ledger.
  defp control_class(errors, error_class) do
    [
      "w-full min-h-11 border bg-sunk px-3 py-2 text-base text-ink font-display placeholder:font-ui placeholder:text-ink-faint focus:outline-none disabled:cursor-not-allowed disabled:opacity-40",
      if(errors == [],
        do: "border-rule-strong focus:border-turmeric",
        else: error_class || "border-sindoor"
      )
    ]
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="text-xs text-sindoor-ink">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Icons appear in the bottom navigation and on back and control affordances.
  They do not appear in content: the Chinese labels already say what things are.

  ## Examples

      <.icon name="hero-arrow-left" class="size-5" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition: {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition: {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(GaneshaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GaneshaWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
