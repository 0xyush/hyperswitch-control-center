// A plain table in the dashboard's style, for small lists that need no paging or filters
open Typography

let headerClass = `px-3 py-3 text-left ${body.sm.semibold} text-nd_gray-500 whitespace-nowrap`
let cellClass = `px-3 py-3 ${body.md.medium} text-nd_gray-700 align-top`

@react.component
let make = (
  ~headers: array<string>,
  ~rows: array<array<React.element>>,
  ~emptyText="Nothing yet.",
) => {
  <div className="overflow-x-auto border border-nd_gray-150 rounded-lg">
    <table className="w-full">
      <thead className="bg-nd_gray-25 border-b border-nd_gray-150">
        <tr>
          {headers
          ->Array.map(header => <th key=header className=headerClass> {header->React.string} </th>)
          ->React.array}
        </tr>
      </thead>
      <tbody className="divide-y divide-nd_gray-150">
        {if rows->Array.length == 0 {
          <tr>
            <td className={`${cellClass} text-nd_gray-400`} colSpan={headers->Array.length}>
              {emptyText->React.string}
            </td>
          </tr>
        } else {
          rows
          ->Array.mapWithIndex((cells, rowIndex) =>
            <tr key={rowIndex->Int.toString}>
              {cells
              ->Array.mapWithIndex((cell, cellIndex) =>
                <td key={cellIndex->Int.toString} className=cellClass> cell </td>
              )
              ->React.array}
            </tr>
          )
          ->React.array
        }}
      </tbody>
    </table>
  </div>
}
