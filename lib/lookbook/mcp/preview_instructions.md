# Writing Lookbook previews

Lookbook previews are Ruby classes that render components or partials in isolation.
Each public instance method on a preview class is a **scenario**.

Before writing a preview, call `docs-list` and `docs-show` to see the components
that already exist and the preview conventions this project already follows.
Only use constructor arguments and slots that `docs-show` documents for a component.

## File location and naming

- Put preview files in the project's preview directory (by default `test/components/previews`).
- Name the class after the component it renders, with a `Preview` suffix:
  `ButtonComponent` → `ButtonComponentPreview` in `button_component_preview.rb`.
  Lookbook uses this name to link the preview to the component.
- Subclass `ViewComponent::Preview` (or `Lookbook::Preview` for partial-only previews),
  matching the existing previews in the project.

```ruby
# test/components/previews/button_component_preview.rb
class ButtonComponentPreview < ViewComponent::Preview
  # Default button
  # --------------
  # Use this style for most actions.
  def default
    render ButtonComponent.new do
      "Click me"
    end
  end
end
```

## What to capture

- A `default` scenario showing the most common usage.
- One scenario per meaningful variant (size, theme, state such as disabled or loading).
- Edge cases: empty content, very long text, missing optional arguments.
- One scenario per slot combination that changes the layout.

## Annotations

Comments directly above a class or method are rendered as notes. Tags customise behaviour:

| Tag | Purpose |
| --- | --- |
| `@label <text>` | Navigation label for the preview or scenario |
| `@param <name> <input_type> "<description>" <opts>` | Makes a method argument editable in the UI |
| `@display <key> <value>` | Passes display options to the preview layout (value parsed as YAML) |
| `@hidden` | Hides the preview or scenario from navigation |
| `@!group <label>` … `@!endgroup` | Renders several scenarios together in one preview |
| `@renders <ComponentClass>` | Declares the render target when it can't be inferred from the class name |
| `@source <path>` | Shows a different file in the source panel |

## Dynamic params

Declare a keyword argument with a default value, then annotate it with `@param`:

```ruby
# @param content text "The text to display in the button"
# @param theme select { choices: [primary, secondary, danger] }
# @param arrow toggle
def playground(content: "Click me", theme: "primary", arrow: true)
  render ButtonComponent.new(theme: theme, arrow: arrow) do
    content
  end
end
```

Input types: `text`, `textarea`, `email`, `number`, `url`, `tel`, `date`,
`datetime-local`, `select`, `toggle`, `color`, `range`.

## Checking your work

After writing a preview, call `docs-show` with the preview class name to confirm Lookbook
picked it up, and open the returned preview URLs to check the rendered output.
