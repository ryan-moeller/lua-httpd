{# vim: set et sw=4: #}

function buildParamField(name) {
    const paramField = document.createElement("div")
    paramField.classList.add("field")
    paramField.classList.add("is-horizontal")
    paramField.dataset.jailParam = name

    const paramFieldLabel = document.createElement("div")
    paramFieldLabel.classList.add("field-label")
    paramFieldLabel.classList.add("is-normal")
    paramField.appendChild(paramFieldLabel)

    const label = document.createElement("label")
    label.classList.add("label")
    label.innerText = name
    paramFieldLabel.appendChild(label)

    const paramFieldBody = document.createElement("div")
    paramFieldBody.classList.add("field-body")
    paramField.appendChild(paramFieldBody)

    const paramFieldBodyField = document.createElement("div")
    paramFieldBodyField.classList.add("field")
    paramFieldBodyField.classList.add("has-addons")
    paramFieldBody.appendChild(paramFieldBodyField)

    const valueControl = document.createElement("div")
    valueControl.classList.add("control")
    valueControl.classList.add("is-expanded")
    paramFieldBodyField.append(valueControl)

    const type = param_types.find((param) => param.name == name).type
    switch (type) {
      case "string": {
        const valueInput = document.createElement("input")
        valueInput.name = name
        valueInput.type = "text"
        valueInput.classList.add("input")
        valueInput.classList.add("is-fullwidth")
        valueControl.appendChild(valueInput)
        break
      }
      case "boolean": {
        const valueInputYes = document.createElement("input")
        valueInputYes.name = name
        valueInputYes.type = "radio"
        valueInputYes.value = "true"
        valueInputYes.checked = true

        const valueLabelYes = document.createElement("label")
        valueLabelYes.classList.add("radio")
        valueLabelYes.appendChild(valueInputYes)
        valueLabelYes.append("True")
        valueControl.appendChild(valueLabelYes)

        const valueInputNo = document.createElement("input")
        valueInputNo.name = name
        valueInputNo.type = "radio"
        valueInputNo.value = "false"

        const valueLabelNo = document.createElement("label")
        valueLabelNo.classList.add("radio")
        valueLabelNo.appendChild(valueInputNo)
        valueLabelNo.append("False")
        valueControl.appendChild(valueLabelNo)
        break
      }
      case "jailsys": {
        const valueInputInherit = document.createElement("input")
        valueInputInherit.name = name
        valueInputInherit.type = "radio"
        valueInputInherit.value = "inherit"
        valueInputInherit.checked = true

        const valueLabelInherit = document.createElement("label")
        valueLabelInherit.classList.add("radio")
        valueLabelInherit.appendChild(valueInputInherit)
        valueLabelInherit.append("Inherit")
        valueControl.appendChild(valueLabelInherit)

        const valueInputNew = document.createElement("input")
        valueInputNew.name = name
        valueInputNew.type = "radio"
        valueInputNew.value = "new"

        const valueLabelNew = document.createElement("label")
        valueLabelNew.classList.add("radio")
        valueLabelNew.appendChild(valueInputNew)
        valueLabelNew.append("New")
        valueControl.appendChild(valueLabelNew)

        const valueInputDisable = document.createElement("input")
        valueInputDisable.name = name
        valueInputDisable.type = "radio"
        valueInputDisable.value = "disable"

        const valueLabelDisable = document.createElement("label")
        valueLabelDisable.classList.add("radio")
        valueLabelDisable.appendChild(valueInputDisable)
        valueLabelDisable.append("Disable")
        valueControl.appendChild(valueLabelDisable)
        break
      }
      case "integer": {
        const valueInput = document.createElement("input")
        valueInput.name = name
        valueInput.type = "number"
        valueInput.classList.add("input")
        valueInput.classList.add("is-fullwidth")
        valueControl.appendChild(valueInput)
        break
      }
      case "unsigned": {
        const valueInput = document.createElement("input")
        valueInput.name = name
        valueInput.type = "number"
        valueInput.min = 0
        valueInput.classList.add("input")
        valueInput.classList.add("is-fullwidth")
        valueControl.appendChild(valueInput)
        break
      }
      case "in6_addr": {
        const valueInput = document.createElement("input")
        valueInput.name = name
        valueInput.type = "text"
        valueInput.pattern = /[0 - 9 a - fA - F:] * /
        valueInput.classList.add("input")
        valueInput.classList.add("is-fullwidth")
        valueControl.appendChild(valueInput)
        break
      }
      case "in_addr": {
        const valueInput = document.createElement("input")
        valueInput.name = name
        valueInput.type = "text"
        valueInput.pattern = /[0 - 9.] * /
        valueInput.classList.add("input")
        valueInput.classList.add("is-fullwidth")
        valueControl.appendChild(valueInput)
        break
      }
      default: {
        valueControl.appendChild("unhandled param type!")
        break
      }
    }

    const removeControl = document.createElement("div")
    removeControl.classList.add("control")
    paramFieldBodyField.appendChild(removeControl)

    const removeButton = document.createElement("div")
    removeButton.classList.add("button")
    removeButton.classList.add("is-danger")
    removeButton.innerText = "X"
    removeButton.addEventListener("click", (event) => {
        event.target.parentElement.parentElement.parentElement.parentElement.remove()
    })
    removeControl.appendChild(removeButton)

    return paramField
}

function applyTemplate(event) {
    const select = document.querySelector("select#param-templates")
    const where = document.querySelector("div#insert-here")

    const old = where.parentElement.querySelectorAll("div[data-jail-param]")
    for (const param of old) {
        param.remove()
    }

    const params = templates.find((el) => el.name == select.value).params
    for (const param of params) {
        let found = false
        for (const p of old) {
            if (p.dataset.jailParam == param) {
                where.parentElement.insertBefore(p, where)
                found = true
            }
        }
        if (!found) {
            const paramField = buildParamField(param)
            where.parentElement.insertBefore(paramField, where)
        }
    }
}

applyTemplate()

document.querySelector("#use-template").addEventListener("click", applyTemplate)
document.querySelector("#add-param").addEventListener("click", (event) => {
    const select = document.querySelector("select#all-params")
    const paramField = buildParamField(select.value)
    const where = document.querySelector("div#insert-here")
    where.parentElement.insertBefore(paramField, where)
})
